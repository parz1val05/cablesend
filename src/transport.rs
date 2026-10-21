//! Cable transports. Every transport yields a plain byte stream (TcpStream or
//! UnixStream), so protocol/transfer code is identical for all of them.
//!
//!  * Ethernet / Thunderbolt-bridge / USB4-bridge / USB-NCM: these are just IP links
//!    (link-local 169.254/16 or fe80::/10). Use `connect_tcp` + `discovery`.
//!  * Android: `adb forward` (PC -> phone app) and `adb reverse` (phone app -> PC).
//!  * iOS: usbmuxd (Apple Mobile Device Service on Windows, usbmuxd on macOS/Linux).
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::time::Duration;

pub trait Stream: Read + Write + Send {}
impl<T: Read + Write + Send> Stream for T {}

/// Sender-side timeouts: long enough for a person to answer the offer prompt,
/// short enough that a receiver which died does not hang the sender forever.
const SEND_READ_TIMEOUT: Duration = Duration::from_secs(300);
const SEND_WRITE_TIMEOUT: Duration = Duration::from_secs(120);

pub fn connect_tcp(addr: &str) -> io::Result<TcpStream> {
    let sa: SocketAddr = addr.to_socket_addrs()?.next()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "cannot resolve address"))?;
    let s = TcpStream::connect_timeout(&sa, Duration::from_secs(5))?;
    s.set_nodelay(true).ok();
    s.set_read_timeout(Some(SEND_READ_TIMEOUT)).ok();
    s.set_write_timeout(Some(SEND_WRITE_TIMEOUT)).ok();
    Ok(s)
}

// ---------------------------------------------------------------- ADB

/// Where `adb` lives. `$ADB` wins, then PATH, then the usual Android SDK layout —
/// on Windows the SDK installer does not put platform-tools on PATH, so requiring
/// it there would make the app look broken on a perfectly good setup.
fn adb_path() -> &'static str {
    static P: OnceLock<String> = OnceLock::new();
    P.get_or_init(|| {
        let exe = if cfg!(windows) { "adb.exe" } else { "adb" };
        if let Ok(p) = std::env::var("ADB") {
            if !p.is_empty() && Path::new(&p).is_file() { return p; }
        }
        // On PATH?
        if Command::new(exe).arg("--version").output().is_ok() { return exe.to_owned(); }

        let mut roots: Vec<PathBuf> = Vec::new();
        if let Ok(v) = std::env::var("ANDROID_HOME") { roots.push(PathBuf::from(v)); }
        if let Ok(v) = std::env::var("ANDROID_SDK_ROOT") { roots.push(PathBuf::from(v)); }
        if cfg!(windows) {
            for v in ["LOCALAPPDATA", "USERPROFILE", "ProgramFiles", "ProgramFiles(x86)"] {
                if let Ok(base) = std::env::var(v) {
                    roots.push(Path::new(&base).join("Android").join("Sdk"));
                    roots.push(Path::new(&base).join("Android").join("android-sdk"));
                }
            }
        } else if let Ok(home) = std::env::var("HOME") {
            roots.push(Path::new(&home).join("Android").join("Sdk"));
            roots.push(Path::new(&home).join("Library").join("Android").join("sdk"));
            roots.push(PathBuf::from("/usr/lib/android-sdk"));
        }
        for r in roots {
            let p = r.join("platform-tools").join(exe);
            if p.is_file() { return p.to_string_lossy().into_owned(); }
        }
        exe.to_owned() // not found: fail later with a readable message
    })
}

fn adb(serial: Option<&str>, args: &[&str]) -> io::Result<String> {
    let mut c = Command::new(adb_path());
    if let Some(s) = serial { c.args(["-s", s]); }
    let out = c.args(args).output().map_err(|e| io::Error::new(e.kind(),
        format!("cannot run `adb` (install Android platform-tools, or set the ADB variable \
                 to the full path of adb): {e}")))?;
    if !out.status.success() {
        return Err(io::Error::new(io::ErrorKind::Other,
            format!("adb {:?} failed: {}", args, String::from_utf8_lossy(&out.stderr).trim())));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Authorized devices as (serial, state).
pub fn adb_devices() -> io::Result<Vec<(String, String)>> {
    Ok(adb(None, &["devices"])?.lines().skip(1)
        .filter_map(|l| { let mut p = l.split_whitespace(); Some((p.next()?.to_owned(), p.next()?.to_owned())) })
        .collect())
}

/// A TCP connection to the phone that removes its `adb forward` rule when dropped.
/// Without this, every send would leave another forward behind in the adb server.
pub struct AdbStream {
    stream: TcpStream,
    serial: Option<String>,
    local_port: u16,
}

impl Read for AdbStream { fn read(&mut self, b: &mut [u8]) -> io::Result<usize> { self.stream.read(b) } }
impl Write for AdbStream {
    fn write(&mut self, b: &[u8]) -> io::Result<usize> { self.stream.write(b) }
    fn flush(&mut self) -> io::Result<()> { self.stream.flush() }
}
impl Drop for AdbStream {
    fn drop(&mut self) {
        let _ = adb(self.serial.as_deref(), &["forward", "--remove", &format!("tcp:{}", self.local_port)]);
    }
}

/// PC -> phone: expose phone's TCP `remote_port` on a free local port and connect to it.
pub fn adb_connect(serial: Option<&str>, remote_port: u16) -> io::Result<AdbStream> {
    let out = adb(serial, &["forward", "tcp:0", &format!("tcp:{remote_port}")])?;
    let local: u16 = out.trim().parse().map_err(|_| io::Error::new(io::ErrorKind::InvalidData, format!("unexpected adb output: {out}")))?;
    match connect_tcp(&format!("127.0.0.1:{local}")) {
        Ok(stream) => Ok(AdbStream { stream, serial: serial.map(str::to_owned), local_port: local }),
        Err(e) => {
            let _ = adb(serial, &["forward", "--remove", &format!("tcp:{local}")]);
            Err(io::Error::new(e.kind(), format!("phone reachable but app not listening on port {remote_port}: {e}")))
        }
    }
}

/// Port on the PHONE that, via `adb reverse`, leads to the PC receiver.
/// Differs from the phone's own receive port (53317) so the two never collide.
pub const PHONE_TO_PC_PORT: u16 = 53320;

/// Phone -> PC: make the phone's `127.0.0.1:phone_port` reach the PC's `pc_port`.
pub fn adb_reverse(serial: Option<&str>, phone_port: u16, pc_port: u16) -> io::Result<()> {
    adb(serial, &["reverse", &format!("tcp:{phone_port}"), &format!("tcp:{pc_port}")]).map(|_| ())
}

/// Opens the phone -> PC tunnel on every authorized device, and keeps doing it.
///
/// A reverse rule belongs to one device and dies when the cable is pulled or the
/// adb server restarts, so a receiver that set it up once would stop being
/// reachable the next time the phone is replugged. Re-applying is idempotent:
/// adb replaces the rule for the same port. Returns how many devices were set up
/// on the first pass; errors are reported per device and otherwise ignored,
/// because a desktop with no phone attached is the normal case.
pub fn adb_reverse_all(pc_port: u16) -> io::Result<usize> {
    let devices = adb_devices()?;
    let mut n = 0;
    for (serial, state) in devices {
        if state != "device" { continue; }
        if adb_reverse(Some(&serial), PHONE_TO_PC_PORT, pc_port).is_ok() { n += 1; }
    }
    Ok(n)
}

// ---------------------------------------------------------------- usbmuxd (iOS)

/// The usbmuxd socket: a Unix socket on macOS/Linux, a TCP port on Windows.
/// Concrete (not `Box<dyn>`) so read deadlines can be set on it.
enum MuxSock {
    Tcp(TcpStream),
    #[cfg(unix)]
    Unix(std::os::unix::net::UnixStream),
}

impl MuxSock {
    fn set_read_timeout(&self, d: Option<Duration>) -> io::Result<()> {
        match self {
            MuxSock::Tcp(s) => s.set_read_timeout(d),
            #[cfg(unix)]
            MuxSock::Unix(s) => s.set_read_timeout(d),
        }
    }
}

impl Read for MuxSock {
    fn read(&mut self, b: &mut [u8]) -> io::Result<usize> {
        match self {
            MuxSock::Tcp(s) => s.read(b),
            #[cfg(unix)]
            MuxSock::Unix(s) => s.read(b),
        }
    }
}

impl Write for MuxSock {
    fn write(&mut self, b: &[u8]) -> io::Result<usize> {
        match self {
            MuxSock::Tcp(s) => s.write(b),
            #[cfg(unix)]
            MuxSock::Unix(s) => s.write(b),
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        match self {
            MuxSock::Tcp(s) => s.flush(),
            #[cfg(unix)]
            MuxSock::Unix(s) => s.flush(),
        }
    }
}

/// A usbmuxd tunnel to a port inside an iOS app, usable as a plain byte stream.
pub struct Mux(MuxSock);
impl Read for Mux { fn read(&mut self, b: &mut [u8]) -> io::Result<usize> { self.0.read(b) } }
impl Write for Mux {
    fn write(&mut self, b: &[u8]) -> io::Result<usize> { self.0.write(b) }
    fn flush(&mut self) -> io::Result<()> { self.0.flush() }
}

fn mux_open() -> io::Result<MuxSock> {
    #[cfg(unix)]
    {
        let path = std::env::var("USBMUXD_SOCKET_ADDRESS").unwrap_or_else(|_| "/var/run/usbmuxd".into());
        let unix_path = path.strip_prefix("UNIX:").map(str::to_owned)
            .or_else(|| if path.contains(':') { None } else { Some(path.clone()) });
        if let Some(p) = unix_path {
            return Ok(MuxSock::Unix(std::os::unix::net::UnixStream::connect(&p).map_err(|e| io::Error::new(e.kind(),
                format!("usbmuxd not reachable at {p} (on Linux install the usbmuxd package): {e}")))?));
        }
    }
    // Windows (Apple Mobile Device Service / iTunes / Apple Devices app) listens here.
    let a = std::env::var("USBMUXD_SOCKET_ADDRESS").unwrap_or_else(|_| "127.0.0.1:27015".into());
    Ok(MuxSock::Tcp(TcpStream::connect(&a).map_err(|e| io::Error::new(e.kind(),
        format!("usbmuxd not reachable (on Windows install iTunes or the Apple Devices app): {e}")))?))
}

/// Legacy binary usbmuxd packet: len, version(0), request, tag (all u32 LE) + payload.
fn mux_send(s: &mut MuxSock, req: u32, tag: u32, payload: &[u8]) -> io::Result<()> {
    let mut p = Vec::with_capacity(16 + payload.len());
    for v in [16 + payload.len() as u32, 0, req, tag] { p.extend_from_slice(&v.to_le_bytes()); }
    p.extend_from_slice(payload);
    s.write_all(&p)?; s.flush()
}

fn mux_recv(s: &mut MuxSock) -> io::Result<(u32, Vec<u8>)> {
    let mut h = [0u8; 16];
    s.read_exact(&mut h)?;
    let len = u32::from_le_bytes(h[0..4].try_into().unwrap()) as usize;
    let kind = u32::from_le_bytes(h[8..12].try_into().unwrap());
    if !(16..=1 << 20).contains(&len) { return Err(io::Error::new(io::ErrorKind::InvalidData, "bad usbmuxd packet")); }
    let mut body = vec![0u8; len - 16];
    s.read_exact(&mut body)?;
    Ok((kind, body))
}

/// iOS devices currently attached over USB: (device_id, serial/UDID).
pub fn ios_devices() -> io::Result<Vec<(u32, String)>> {
    let mut s = mux_open()?;
    mux_send(&mut s, 3 /* LISTEN */, 1, &[])?;
    // usbmuxd answers RESULT, then one DEVICE_ADD per attached device, then stays silent
    // holding the connection open. Read until that silence instead of parking a thread on it.
    s.set_read_timeout(Some(Duration::from_millis(400)))?;
    let mut devs = Vec::new();
    loop {
        match mux_recv(&mut s) {
            Ok((kind, body)) if kind == 4 && body.len() >= 6 => {
                let id = u32::from_le_bytes(body[0..4].try_into().unwrap());
                let serial: Vec<u8> = body[6..].iter().take(256).take_while(|b| **b != 0).cloned().collect();
                devs.push((id, String::from_utf8_lossy(&serial).into_owned()));
            }
            Ok(_) => continue,
            Err(_) => break, // timeout (no more devices) or a closed socket
        }
    }
    Ok(devs)
}

/// Open a tunnel to TCP `port` inside the iPhone app (which must be in the foreground).
pub fn ios_connect(udid_or_id: Option<&str>, port: u16) -> io::Result<Mux> {
    let devs = ios_devices()?;
    let id = match udid_or_id {
        Some(q) => devs.iter().find(|(i, s)| s == q || i.to_string() == q).map(|d| d.0),
        None => devs.first().map(|d| d.0),
    }.ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no iOS device (unlock it and tap \"Trust\")"))?;
    let mut s = mux_open()?;
    let mut p = Vec::new();
    p.extend_from_slice(&id.to_le_bytes());
    p.extend_from_slice(&port.to_be_bytes()); // port is network byte order
    p.extend_from_slice(&[0, 0]);
    mux_send(&mut s, 2 /* CONNECT */, 2, &p)?;
    s.set_read_timeout(Some(Duration::from_secs(10)))?;
    let (kind, body) = mux_recv(&mut s)?;
    let code = if kind == 1 && body.len() >= 4 { u32::from_le_bytes(body[0..4].try_into().unwrap()) } else { 99 };
    if code != 0 { return Err(io::Error::new(io::ErrorKind::ConnectionRefused,
        format!("usbmuxd connect refused (code {code}); is the app open on the phone and listening on port {port}?"))); }
    // From here on the socket carries the app's own stream: use the sender timeouts.
    s.set_read_timeout(Some(SEND_READ_TIMEOUT))?;
    Ok(Mux(s))
}
