//! C ABI used by the Flutter app on Android / iOS (and usable from any language).
//!
//! Design: no callbacks and no JSON parsing across the boundary.
//!  * Commands take plain C strings / integers and return immediately; work runs on threads.
//!  * Results come back as JSON text events pulled with `cs_next_event()` (poll from a timer).
//!  * Strings returned by the library must be released with `cs_free_string()`.
//!
//! Events (one JSON object each; `dir` is "in" for receiving, "out" for sending):
//!   {"event":"listening","port":N}
//!   {"event":"offer","peer":..,"platform":..,"files":[{"name":..,"size":N}]}
//!   {"event":"progress","dir":..,"name":..,"done":N,"total":N}
//!   {"event":"done","dir":..,"files":N}
//!   {"event":"error","dir":..,"message":..}
//!   {"event":"scan","peers":[{"id":..,"name":..,"platform":..,"addr":"host:port","via":"net"|"usb"}]}
use crate::{discovery, json::esc, transfer, transport};
use std::collections::VecDeque;
use std::ffi::{c_char, CStr, CString};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

struct Engine {
    events: Mutex<VecDeque<String>>,
    rx_stop: Mutex<Option<Arc<AtomicBool>>>,
    answer: Mutex<Option<mpsc::Sender<bool>>>,
}

/// This device's beacon identity, so `cs_scan` never lists this device itself.
fn instance_id() -> &'static str {
    static ID: OnceLock<String> = OnceLock::new();
    ID.get_or_init(discovery::default_instance_id)
}

fn eng() -> &'static Engine {
    static E: OnceLock<Engine> = OnceLock::new();
    E.get_or_init(|| Engine { events: Mutex::new(VecDeque::new()), rx_stop: Mutex::new(None), answer: Mutex::new(None) })
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

fn push(ev: String) {
    let mut q = lock(&eng().events);
    if q.len() > 5000 { q.pop_front(); }
    q.push_back(ev);
}

unsafe fn cstr(p: *const c_char) -> String {
    if p.is_null() { String::new() } else { CStr::from_ptr(p).to_string_lossy().into_owned() }
}

fn spawn_guarded(dir: &'static str, f: impl FnOnce() + Send + 'static) {
    std::thread::spawn(move || {
        if catch_unwind(AssertUnwindSafe(f)).is_err() {
            push(format!("{{\"event\":\"error\",\"dir\":\"{dir}\",\"message\":\"internal error\"}}"));
        }
    });
}

/// Emits at most ~12 progress events per second per transfer, always the last one.
fn progress_sink(dir: &'static str) -> impl FnMut(&str, u64, u64) {
    let mut last = Instant::now() - Duration::from_secs(1);
    move |name, done, total| {
        if done == total || last.elapsed() >= Duration::from_millis(80) {
            last = Instant::now();
            push(format!("{{\"event\":\"progress\",\"dir\":\"{dir}\",\"name\":\"{}\",\"done\":{done},\"total\":{total}}}", esc(name)));
        }
    }
}

#[no_mangle]
pub extern "C" fn cs_version() -> u32 { 1 }

/// Next pending event as a JSON string, or NULL if none. Free with `cs_free_string`.
#[no_mangle]
pub extern "C" fn cs_next_event() -> *mut c_char {
    match lock(&eng().events).pop_front() {
        Some(s) => CString::new(s.replace('\0', " ")).map(CString::into_raw).unwrap_or(std::ptr::null_mut()),
        None => std::ptr::null_mut(),
    }
}

/// # Safety
/// `p` must come from `cs_next_event` and not have been freed already.
#[no_mangle]
pub unsafe extern "C" fn cs_free_string(p: *mut c_char) {
    if !p.is_null() { drop(CString::from_raw(p)); }
}

/// Look for peers (UDP beacon on cable links, the `adb reverse` tunnel to a PC, and the
/// USB bridge to another phone). Result arrives as a `scan` event.
#[no_mangle]
pub extern "C" fn cs_scan(beacon_port: u16) {
    spawn_guarded("out", move || {
        let mut items: Vec<String> = Vec::new();
        if let Ok(found) = discovery::find_peers(beacon_port, Duration::from_millis(1500), instance_id()) {
            for f in found {
                if f.addr.ip().is_loopback() { continue; }
                items.push(format!("{{\"id\":\"{}\",\"name\":\"{}\",\"platform\":\"{}\",\"addr\":\"{}\",\"via\":\"net\"}}", esc(&f.id), esc(&f.name), esc(&f.platform), f.addr));
            }
        }
        if probe_receiver(transport::PHONE_TO_PC_PORT).is_some() {
            let addr = format!("127.0.0.1:{}", transport::PHONE_TO_PC_PORT);
            items.push(format!("{{\"id\":\"usb-host\",\"name\":\"Компьютер\",\"platform\":\"desktop\",\"addr\":\"{addr}\",\"via\":\"usb\"}}"));
        }
        // Only answers when another phone is on the cable AND has receiving switched on.
        if let Some(p) = probe_receiver(transport::PHONE_TO_PHONE_PORT) {
            let addr = format!("127.0.0.1:{}", transport::PHONE_TO_PHONE_PORT);
            items.push(format!("{{\"id\":\"usb-phone\",\"name\":\"{}\",\"platform\":\"{}\",\"addr\":\"{addr}\",\"via\":\"usb\"}}", esc(&p.name), esc(&p.platform)));
        }
        push(format!("{{\"event\":\"scan\",\"peers\":[{}]}}", items.join(",")));
    });
}

/// Is a receiver reachable through a local tunnel port, and who is it?
///
/// `adb reverse` (and the USB bridge when the other phone is not receiving) accepts the
/// connection even when nobody is behind it, then closes it. A live receiver greets every
/// connection with its HELLO frame straight away (`proto::hello` writes before it reads),
/// so "a HELLO arrived" means "alive". The receiver then sees us leave before an OFFER
/// and treats it as a probe.
fn probe_receiver(port: u16) -> Option<crate::proto::Peer> {
    let addr: SocketAddr = ([127, 0, 0, 1], port).into();
    let mut s = TcpStream::connect_timeout(&addr, Duration::from_millis(250)).ok()?;
    s.set_read_timeout(Some(Duration::from_millis(1500))).ok();
    let f = crate::proto::read_frame(&mut s).ok()?;
    (f.len() >= 4 && f[0] == "HELLO").then(|| crate::proto::Peer { name: f[2].clone(), platform: f[3].clone() })
}

/// Start receiving. Returns the bound port (>0), -1 if already running, -2 if the port is unavailable.
#[no_mangle]
pub unsafe extern "C" fn cs_receive_start(dir: *const c_char, name: *const c_char, port: u16, beacon_port: u16) -> i32 {
    let (dir, name) = (PathBuf::from(cstr(dir)), cstr(name));
    // A receiver that was told to stop needs up to ~100 ms to leave its accept loop.
    for _ in 0..20 {
        let stopping = matches!(lock(&eng().rx_stop).as_ref(), Some(f) if f.load(Ordering::Relaxed));
        if !stopping { break; }
        std::thread::sleep(Duration::from_millis(50));
    }
    let mut slot = lock(&eng().rx_stop);
    if slot.is_some() { return -1; }
    let Ok(listener) = TcpListener::bind(("0.0.0.0", port)) else { return -2 };
    if listener.set_nonblocking(true).is_err() { return -2; }
    let bound = listener.local_addr().map(|a| a.port()).unwrap_or(port);
    let stop = Arc::new(AtomicBool::new(false));
    *slot = Some(stop.clone());
    drop(slot);
    push(format!("{{\"event\":\"listening\",\"port\":{bound}}}"));

    spawn_guarded("in", move || {
        let _beacon = discovery::start_beacon(instance_id(), &name, bound, beacon_port).ok();
        while !stop.load(Ordering::Relaxed) {
            let mut s = match listener.accept() {
                Ok((s, _)) => s,
                Err(_) => { std::thread::sleep(Duration::from_millis(100)); continue; }
            };
            s.set_nonblocking(false).ok();
            s.set_nodelay(true).ok();
            s.set_read_timeout(Some(Duration::from_secs(60))).ok();
            let mut offered = false;
            let mut sink = progress_sink("in");
            let res = transfer::receive_files(&mut s, &name, &dir, &mut |peer, offers| {
                offered = true;
                let files: Vec<String> = offers.iter().map(|(n, sz)| format!("{{\"name\":\"{}\",\"size\":{sz}}}", esc(n))).collect();
                let (tx, rx) = mpsc::channel();
                *lock(&eng().answer) = Some(tx);
                push(format!("{{\"event\":\"offer\",\"peer\":\"{}\",\"platform\":\"{}\",\"files\":[{}]}}", esc(&peer.name), esc(&peer.platform), files.join(",")));
                let ok = rx.recv_timeout(Duration::from_secs(90)).unwrap_or(false);
                *lock(&eng().answer) = None;
                ok
            }, &mut sink);
            match res {
                Ok(f) => push(format!("{{\"event\":\"done\",\"dir\":\"in\",\"files\":{}}}", f.len())),
                // A peer that connects and leaves before offering anything is a liveness probe.
                Err(e) if !offered && transfer::is_disconnect(e.kind()) => {}
                // The person said no. Already reported by the UI; not a failure.
                Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {}
                Err(e) => push(format!("{{\"event\":\"error\",\"dir\":\"in\",\"message\":\"{}\"}}", esc(&e.to_string()))),
            }
        }
        *lock(&eng().rx_stop) = None;
    });
    bound as i32
}

#[no_mangle]
pub extern "C" fn cs_receive_stop() {
    if let Some(stop) = lock(&eng().rx_stop).as_ref() { stop.store(true, Ordering::Relaxed); }
    if let Some(tx) = lock(&eng().answer).take() { let _ = tx.send(false); }
}

/// Answer the pending offer: 1 = accept, 0 = decline.
#[no_mangle]
pub extern "C" fn cs_answer(accept: i32) {
    if let Some(tx) = lock(&eng().answer).take() { let _ = tx.send(accept != 0); }
}

/// Send files to `to` ("host:port"). `files` is a newline-separated list of absolute paths.
#[no_mangle]
pub unsafe extern "C" fn cs_send(to: *const c_char, name: *const c_char, files: *const c_char) {
    let (to, name, files) = (cstr(to), cstr(name), cstr(files));
    spawn_guarded("out", move || {
        let paths: Vec<PathBuf> = files.lines().filter(|l| !l.is_empty()).map(PathBuf::from).collect();
        let result = transport::connect_tcp(&to).and_then(|mut s| {
            let mut sink = progress_sink("out");
            transfer::send_files(&mut s, &name, &paths, &mut sink)
        });
        match result {
            Ok(n) => push(format!("{{\"event\":\"done\",\"dir\":\"out\",\"files\":{n}}}")),
            Err(e) => push(format!("{{\"event\":\"error\",\"dir\":\"out\",\"message\":\"{}\"}}", esc(&e.to_string()))),
        }
    });
}

#[cfg(test)]
mod tests {
    use super::probe_receiver;
    use std::net::TcpListener;

    #[test]
    fn probe_sees_a_live_receiver() {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let t = std::thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            // a real receiver: greets first, then sees the probe leave
            let _ = crate::proto::hello(&mut s, "rx");
        });
        assert_eq!(probe_receiver(port).map(|p| p.name).as_deref(), Some("rx"));
        t.join().unwrap();
    }

    #[test]
    fn probe_rejects_a_tunnel_with_nobody_behind_it() {
        // what `adb reverse` does when no PC receiver runs: accept, then close
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let t = std::thread::spawn(move || drop(l.accept().unwrap()));
        assert!(probe_receiver(port).is_none());
        t.join().unwrap();
    }
}
