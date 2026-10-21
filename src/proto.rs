//! Wire protocol, transport-agnostic. Works over ANY ordered byte stream
//! (TCP over Ethernet/Thunderbolt, ADB-forwarded TCP, usbmuxd tunnel).
//!
//! Frame  = u32 big-endian length + UTF-8 text, fields separated by '\t'.
//! Flow   : both sides HELLO -> sender OFFER n + n x FILE -> receiver ACCEPT|REJECT
//!          -> per file: raw bytes, END <sha256>, receiver OK|ERR <msg>.
use std::io::{self, Read, Write};

pub const PROTO_VERSION: u32 = 1;
const MAX_FRAME: u32 = 64 * 1024;

pub fn write_frame<W: Write>(w: &mut W, fields: &[&str]) -> io::Result<()> {
    let s = fields.join("\t");
    w.write_all(&(s.len() as u32).to_be_bytes())?;
    w.write_all(s.as_bytes())?;
    w.flush()
}

pub fn read_frame<R: Read>(r: &mut R) -> io::Result<Vec<String>> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len)?;
    let n = u32::from_be_bytes(len);
    if n > MAX_FRAME {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "frame too large"));
    }
    let mut buf = vec![0u8; n as usize];
    r.read_exact(&mut buf)?;
    let s = String::from_utf8(buf).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "bad utf8"))?;
    Ok(s.split('\t').map(str::to_owned).collect())
}

pub struct Peer { pub name: String, pub platform: String }

pub fn hello<S: Read + Write>(s: &mut S, name: &str) -> io::Result<Peer> {
    write_frame(s, &["HELLO", &PROTO_VERSION.to_string(), name, std::env::consts::OS])?;
    let f = read_frame(s)?;
    if f.len() < 4 || f[0] != "HELLO" {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "expected HELLO"));
    }
    if f[1].parse::<u32>().ok() != Some(PROTO_VERSION) {
        return Err(io::Error::new(io::ErrorKind::InvalidData, format!("protocol version mismatch: peer {}", f[1])));
    }
    Ok(Peer { name: f[2].clone(), platform: f[3].clone() })
}
