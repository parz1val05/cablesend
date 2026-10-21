use cablesend::{discovery, transfer, transport};
use std::io::{self, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::time::Duration;

const DEFAULT_PORT: u16 = 53317;
const DEFAULT_BEACON: u16 = 53318;

const HELP: &str = "cablesend - cable-first file transfer (prototype)

USAGE
  cablesend devices [--json]
  cablesend adb-reverse [--port P]   # открыть туннель «телефон → ПК» и выйти
  cablesend peers [--json] [--beacon-port B] [--id ID]
  cablesend receive [--dir D] [--port P] [--name N] [--auto-accept] [--once]
                    [--beacon-port B] [--no-beacon] [--adb-reverse [SERIAL]] [--json] [--id ID]
  cablesend send FILES... ( --to HOST:PORT | --discover
                          | --adb [SERIAL] --remote-port P
                          | --ios [UDID] --remote-port P ) [--name N] [--beacon-port B] [--json]

--json: machine-readable events on stdout (one JSON object per line) for GUI front-ends.
        In --json receive mode an offer is answered by a line y or n on stdin.
--id:   this device's beacon identity. Pass the SAME id to `receive` and to `peers`
        (they are separate processes) so the device never lists itself as a peer.
";

struct Args { v: Vec<String> }
impl Args {
    fn flag(&mut self, f: &str) -> bool { if let Some(i) = self.v.iter().position(|a| a == f) { self.v.remove(i); true } else { false } }
    fn opt(&mut self, f: &str) -> Option<String> {
        let i = self.v.iter().position(|a| a == f)?;
        self.v.remove(i);
        if i < self.v.len() { Some(self.v.remove(i)) } else { None }
    }
    /// Optional value that must not look like another flag / file.
    fn opt_maybe(&mut self, f: &str) -> Option<Option<String>> {
        let i = self.v.iter().position(|a| a == f)?;
        self.v.remove(i);
        if i < self.v.len() && !self.v[i].starts_with("--") && !std::path::Path::new(&self.v[i]).exists() { Some(Some(self.v.remove(i))) } else { Some(None) }
    }
}

fn host_name() -> String {
    std::env::var("COMPUTERNAME").or_else(|_| std::env::var("HOSTNAME")).or_else(|_| std::env::var("USER")).unwrap_or_else(|_| "device".into())
}

fn human(n: u64) -> String {
    let u = ["B", "KB", "MB", "GB", "TB"]; let mut f = n as f64; let mut i = 0;
    while f >= 1024.0 && i < 4 { f /= 1024.0; i += 1; }
    format!("{:.1} {}", f, u[i])
}

fn jesc(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""), '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"), '\r' => o.push_str("\\r"), '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o
}

fn json_progress(name: &str, done: u64, total: u64) {
    emit(format!("{{\"event\":\"progress\",\"name\":\"{}\",\"done\":{done},\"total\":{total}}}", jesc(name)));
}

fn emit(line: String) { println!("{line}"); let _ = io::stdout().flush(); }

fn progress(name: &str, done: u64, total: u64) {
    let pct = if total == 0 { 100 } else { done * 100 / total };
    eprint!("\r  {name}: {pct:3}% ({} / {})   ", human(done), human(total));
    if done == total { eprintln!(); }
}

fn main() -> io::Result<()> {
    let mut a = Args { v: std::env::args().skip(1).collect() };
    if a.v.is_empty() || a.flag("--help") || a.flag("-h") { print!("{HELP}"); return Ok(()); }
    let cmd = a.v.remove(0);
    let name = a.opt("--name").unwrap_or_else(host_name);
    let json = a.flag("--json");
    let beacon_port: u16 = a.opt("--beacon-port").and_then(|p| p.parse().ok()).unwrap_or(DEFAULT_BEACON);
    let id = a.opt("--id").unwrap_or_else(discovery::default_instance_id);

    match cmd.as_str() {
        "devices" => {
            if json {
                let (ad, ae) = match transport::adb_devices() { Ok(d) => (d, None), Err(e) => (vec![], Some(e.to_string())) };
                let (id, ie) = match transport::ios_devices() { Ok(d) => (d, None), Err(e) => (vec![], Some(e.to_string())) };
                let a_items: Vec<String> = ad.iter().map(|(s, st)| format!("{{\"id\":\"{}\",\"state\":\"{}\"}}", jesc(s), jesc(st))).collect();
                let i_items: Vec<String> = id.iter().map(|(i, s)| format!("{{\"id\":\"{}\",\"state\":\"device\",\"mux_id\":{i}}}", jesc(s))).collect();
                let err = |e: &Option<String>| e.as_ref().map(|m| format!("\"{}\"", jesc(m))).unwrap_or("null".into());
                emit(format!("{{\"android\":{{\"devices\":[{}],\"error\":{}}},\"ios\":{{\"devices\":[{}],\"error\":{}}}}}",
                    a_items.join(","), err(&ae), i_items.join(","), err(&ie)));
                return Ok(());
            }
            match transport::adb_devices() { Ok(d) if !d.is_empty() => for (s, st) in d { println!("android  {s}  [{st}]") }, Ok(_) => println!("android  (none)"), Err(e) => println!("android  unavailable: {e}") }
            match transport::ios_devices() { Ok(d) if !d.is_empty() => for (i, s) in d { println!("ios      {s}  (id {i})") }, Ok(_) => println!("ios      (none)"), Err(e) => println!("ios      unavailable: {e}") }
            Ok(())
        }
        "adb-reverse" => {
            let port: u16 = a.opt("--port").and_then(|p| p.parse().ok()).unwrap_or(DEFAULT_PORT);
            let n = transport::adb_reverse_all(port)?;
            if json {
                emit(format!("{{\"devices\":{n},\"phone_port\":{}}}", transport::PHONE_TO_PC_PORT));
            } else {
                println!("Туннель открыт на устройствах: {n} (порт {} на телефоне ведёт к ПК:{port})", transport::PHONE_TO_PC_PORT);
            }
            Ok(())
        }
        "peers" => {
            let peers = discovery::find_peers(beacon_port, Duration::from_secs(2), &id)?;
            if json {
                let items: Vec<String> = peers.iter().map(|p| format!("{{\"id\":\"{}\",\"name\":\"{}\",\"platform\":\"{}\",\"addr\":\"{}\"}}", jesc(&p.id), jesc(&p.name), jesc(&p.platform), p.addr)).collect();
                emit(format!("{{\"peers\":[{}]}}", items.join(",")));
            } else {
                for p in &peers { println!("{}  {}  {}", p.name, p.platform, p.addr); }
                if peers.is_empty() { println!("(no peers)"); }
            }
            Ok(())
        }
        "receive" => {
            let dir = PathBuf::from(a.opt("--dir").unwrap_or_else(|| "received".into()));
            let port: u16 = a.opt("--port").and_then(|p| p.parse().ok()).unwrap_or(DEFAULT_PORT);
            let auto = a.flag("--auto-accept");
            let once = a.flag("--once");
            let no_beacon = a.flag("--no-beacon");
            let adb_reverse = a.opt_maybe("--adb-reverse");
            let l = TcpListener::bind(("0.0.0.0", port))?;
            let port = l.local_addr()?.port();
            let _beacon = if no_beacon { None } else { Some(discovery::start_beacon(&id, &name, port, beacon_port)?) };

            // Keep the phone -> PC USB tunnel open for every attached Android device.
            // A reverse rule is per-device and dies when the cable is pulled, so this
            // re-applies it instead of setting it up once. Failures are silent: a
            // desktop with no phone plugged in (or no adb at all) is normal.
            if let Some(serial) = adb_reverse {
                let bound = port;
                std::thread::spawn(move || loop {
                    let r = match serial.as_deref() {
                        Some(s) => transport::adb_reverse(Some(s), transport::PHONE_TO_PC_PORT, bound).map(|_| 1),
                        None => transport::adb_reverse_all(bound),
                    };
                    if let Ok(n) = r {
                        if n > 0 && json {
                            emit(format!("{{\"event\":\"usb_tunnel\",\"devices\":{n},\"phone_port\":{}}}", transport::PHONE_TO_PC_PORT));
                        }
                    }
                    std::thread::sleep(Duration::from_secs(3));
                });
            }
            if json { emit(format!("{{\"event\":\"listening\",\"port\":{port},\"name\":\"{}\",\"folder\":\"{}\"}}", jesc(&name), jesc(&dir.display().to_string()))); }
            else { eprintln!("Listening on port {port} as \"{name}\", saving to {}", dir.display()); }
            for conn in l.incoming() {
                let mut s = match conn { Ok(s) => s, Err(e) => { eprintln!("accept: {e}"); continue } };
                let peer_addr = s.peer_addr().ok();
                s.set_nodelay(true).ok();
                let mut offered = false;
                let res = transfer::receive_files(&mut s, &name, &dir, &mut |peer, offers| {
                    offered = true;
                    if json {
                        let files: Vec<String> = offers.iter().map(|(n, sz)| format!("{{\"name\":\"{}\",\"size\":{sz}}}", jesc(n))).collect();
                        emit(format!("{{\"event\":\"offer\",\"peer\":\"{}\",\"platform\":\"{}\",\"files\":[{}]}}", jesc(&peer.name), jesc(&peer.platform), files.join(",")));
                        if auto { return true; }
                        let mut line = String::new(); io::stdin().read_line(&mut line).ok();
                        return line.trim().eq_ignore_ascii_case("y");
                    }
                    eprintln!("{} ({}) wants to send {} file(s):", peer.name, peer.platform, offers.len());
                    for (n, sz) in offers { eprintln!("  {n} ({})", human(*sz)); }
                    if auto { return true; }
                    eprint!("Accept? [y/N] "); io::stderr().flush().ok();
                    let mut line = String::new(); io::stdin().read_line(&mut line).ok();
                    line.trim().eq_ignore_ascii_case("y")
                }, &mut |n, d, t| if json { json_progress(n, d, t) } else { progress(n, d, t) });
                // A peer that connects and leaves before offering anything is a liveness probe: ignore.
                if !offered && matches!(&res, Err(e) if transfer::is_disconnect(e.kind())) { continue; }
                if matches!(&res, Err(e) if e.kind() == io::ErrorKind::PermissionDenied) {
                    if !json { eprintln!("Отклонено."); }
                    if once { break; }
                    continue;
                }
                match res {
                    Ok(f) => if json { emit(format!("{{\"event\":\"done\",\"files\":{}}}", f.len())) } else { eprintln!("Saved {} file(s) from {:?}", f.len(), peer_addr) },
                    Err(e) => if json { emit(format!("{{\"event\":\"error\",\"message\":\"{}\"}}", jesc(&e.to_string()))) } else { eprintln!("Transfer failed: {e}") },
                }
                if once { break; }
            }
            Ok(())
        }
        "send" => {
            let to = a.opt("--to");
            let discover = a.flag("--discover");
            let adb = a.opt_maybe("--adb");
            let ios = a.opt_maybe("--ios");
            let remote_port: u16 = a.opt("--remote-port").and_then(|p| p.parse().ok()).unwrap_or(DEFAULT_PORT);
            let files: Vec<PathBuf> = a.v.iter().map(PathBuf::from).collect();
            if files.is_empty() { eprintln!("no files given\n{HELP}"); std::process::exit(2); }
            let mut s: Box<dyn transport::Stream> = if let Some(addr) = to {
                Box::new(transport::connect_tcp(&addr)?)
            } else if let Some(serial) = adb {
                Box::new(transport::adb_connect(serial.as_deref(), remote_port)?)
            } else if let Some(udid) = ios {
                Box::new(transport::ios_connect(udid.as_deref(), remote_port)?)
            } else if discover {
                eprintln!("Searching for peers on cable links...");
                let peers = discovery::find_peers(beacon_port, Duration::from_secs(3), &id)?;
                let p = peers.first().ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no peers found"))?;
                eprintln!("Found {} ({}) at {}", p.name, p.platform, p.addr);
                Box::new(transport::connect_tcp(&p.addr.to_string())?)
            } else { eprintln!("choose --to, --discover, --adb or --ios\n{HELP}"); std::process::exit(2) };
            let r = transfer::send_files(&mut s, &name, &files, &mut |n, d, t| if json { json_progress(n, d, t) } else { progress(n, d, t) });
            match r {
                Ok(n) => { if json { emit(format!("{{\"event\":\"done\",\"files\":{n}}}")) } else { eprintln!("Sent {n} file(s)."); } Ok(()) }
                Err(e) => { if json { emit(format!("{{\"event\":\"error\",\"message\":\"{}\"}}", jesc(&e.to_string()))); std::process::exit(1) } else { Err(e) } }
            }
        }
        _ => { eprint!("{HELP}"); std::process::exit(2) }
    }
}
