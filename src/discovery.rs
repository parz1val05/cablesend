//! Peer discovery on an IP cable link: UDP broadcast beacon.
//! Works on direct Ethernet (169.254/16 auto-IP) and Thunderbolt/USB4 bridge interfaces.
//! Production: send per-interface (directed broadcast + ff02::1 for IPv6 link-local).
use std::io;
use std::net::{SocketAddr, UdpSocket};
use std::sync::{atomic::{AtomicBool, Ordering}, Arc};
use std::time::{Duration, Instant};

const MAGIC: &str = "CABLESEND2";

/// Identity of this *receiver* on the network, used so a device never lists itself.
/// A process-wide value by default; the GUI passes the same id to the `receive` and
/// `peers` child processes, which are separate processes on the same machine.
pub fn default_instance_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let t = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let mut h = crate::sha256::Sha256::new();
    h.update(&t.to_le_bytes());
    h.update(&std::process::id().to_le_bytes());
    h.update(std::env::consts::OS.as_bytes());
    h.finish_hex()[..16].to_owned()
}

pub struct Beacon { pub stop: Arc<AtomicBool> }
impl Drop for Beacon { fn drop(&mut self) { self.stop.store(true, Ordering::Relaxed); } }

pub fn start_beacon(id: &str, name: &str, tcp_port: u16, beacon_port: u16) -> io::Result<Beacon> {
    let sock = UdpSocket::bind("0.0.0.0:0")?;
    sock.set_broadcast(true)?;
    let msg = format!("{MAGIC}\t{}\t{}\t{}\t{}", id.replace('\t', ""), name.replace('\t', " "), std::env::consts::OS, tcp_port);
    let stop = Arc::new(AtomicBool::new(false));
    let st = stop.clone();
    std::thread::spawn(move || {
        while !st.load(Ordering::Relaxed) {
            let _ = sock.send_to(msg.as_bytes(), ("255.255.255.255", beacon_port));
            let _ = sock.send_to(msg.as_bytes(), ("127.0.0.1", beacon_port)); // same-host testing
            std::thread::sleep(Duration::from_millis(700));
        }
    });
    Ok(Beacon { stop })
}

#[derive(Debug, Clone)]
pub struct Found { pub id: String, pub name: String, pub platform: String, pub addr: SocketAddr }

/// Collects beacons for `wait`. Beacons whose instance id equals `own_id` are ours and skipped,
/// which is what keeps a device out of its own peer list (its broadcast comes back on its own IP).
pub fn find_peers(beacon_port: u16, wait: Duration, own_id: &str) -> io::Result<Vec<Found>> {
    // Another scan (or another app instance) may hold the port for a moment: retry briefly.
    let mut tries = 0;
    let sock = loop {
        match UdpSocket::bind(("0.0.0.0", beacon_port)) {
            Ok(s) => break s,
            Err(e) if e.kind() == io::ErrorKind::AddrInUse && tries < 8 => {
                tries += 1;
                std::thread::sleep(Duration::from_millis(250));
            }
            Err(e) => return Err(e),
        }
    };
    let end = Instant::now() + wait;
    let mut out: Vec<Found> = Vec::new();
    let mut buf = [0u8; 512];
    while Instant::now() < end {
        sock.set_read_timeout(Some(end.saturating_duration_since(Instant::now()).max(Duration::from_millis(1))))?;
        let Ok((n, from)) = sock.recv_from(&mut buf) else { continue };
        let text = String::from_utf8_lossy(&buf[..n]);
        let p: Vec<&str> = text.split('\t').collect();
        if p.len() == 5 && p[0] == MAGIC && p[1] != own_id {
            if let Ok(port) = p[4].parse::<u16>() {
                let addr = SocketAddr::new(from.ip(), port);
                // One beacon reaches us once per route (broadcast and loopback), so the same
                // device arrives under several addresses. Keep one entry per device and prefer
                // the routable address, since loopback only works on this machine.
                match out.iter_mut().find(|f| f.id == p[1]) {
                    Some(seen) => {
                        if seen.addr.ip().is_loopback() && !addr.ip().is_loopback() { seen.addr = addr; }
                    }
                    None => out.push(Found { id: p[1].into(), name: p[2].into(), platform: p[3].into(), addr }),
                }
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn own_beacon_is_not_listed() {
        let id = default_instance_id();
        let _b = start_beacon(&id, "me", 1234, 54391).unwrap();
        let found = find_peers(54391, Duration::from_millis(1600), &id).unwrap();
        assert!(found.is_empty(), "device listed itself: {found:?}");
    }

    #[test]
    fn other_beacon_is_listed() {
        let _b = start_beacon("someone-else", "peer", 4321, 54392).unwrap();
        let found = find_peers(54392, Duration::from_millis(1600), &default_instance_id()).unwrap();
        assert_eq!(found.len(), 1, "expected one peer, got {found:?}");
        assert_eq!(found[0].name, "peer");
        assert_eq!(found[0].addr.port(), 4321);
    }

    #[test]
    fn one_entry_per_device_even_though_beacons_arrive_twice() {
        let _b = start_beacon("dup-test-id", "peer", 4321, 54393).unwrap();
        let found = find_peers(54393, Duration::from_millis(1600), &default_instance_id()).unwrap();
        assert_eq!(found.len(), 1, "device listed more than once: {found:?}");
        assert!(!found[0].addr.ip().is_loopback(), "kept the loopback address: {found:?}");
    }

    #[test]
    fn two_ids_differ() {
        assert_ne!(default_instance_id(), default_instance_id());
    }
}
