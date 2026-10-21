use crate::proto::*;
use crate::sha256::Sha256;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc;

const CHUNK: usize = 256 * 1024;
/// Chunks in flight between the network thread and the disk+hash thread. Lets the
/// cable, the disk and SHA-256 work at the same time instead of taking turns.
const PIPELINE: usize = 4;
/// Room left on the receiver's disk beyond the files themselves.
const SPACE_MARGIN: u64 = 16 * 1024 * 1024;

/// A file to send: already open, so a file handed over as a descriptor (Android
/// content URIs, see `ffi::cs_send`) is sent exactly like one opened by path.
pub struct Source {
    pub file: File,
    pub name: String,
    pub size: u64,
}

impl Source {
    pub fn open(path: &Path) -> io::Result<Source> {
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let file = File::open(path)?;
        Source::from_file(file, &name).map_err(|e| io::Error::new(e.kind(), format!("{}: {e}", path.display())))
    }

    pub fn from_file(file: File, name: &str) -> io::Result<Source> {
        let md = file.metadata()?;
        if !md.is_file() { return Err(io::Error::new(io::ErrorKind::InvalidInput, format!("not a file: {name}"))); }
        Ok(Source { file, name: clean_field(name), size: md.len() })
    }
}

pub fn human_size(n: u64) -> String {
    let u = ["B", "KB", "MB", "GB", "TB"];
    let mut f = n as f64;
    let mut i = 0;
    while f >= 1024.0 && i < 4 { f /= 1024.0; i += 1; }
    format!("{:.1} {}", f, u[i])
}

/// Errors that just mean "the other side went away" (also what a liveness probe looks like).
pub fn is_disconnect(kind: io::ErrorKind) -> bool {
    use io::ErrorKind::*;
    matches!(kind, UnexpectedEof | BrokenPipe | ConnectionReset | ConnectionAborted | TimedOut | WouldBlock)
}

fn clean_field(s: &str) -> String {
    s.chars().map(|c| if c == '\t' || c == '\n' || c == '\r' { ' ' } else { c }).collect()
}

/// Names Windows refuses to use for a file, whatever the extension.
const RESERVED: [&str; 22] = ["CON", "PRN", "AUX", "NUL",
    "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"];

const MAX_NAME_BYTES: usize = 150;

/// Makes a peer-supplied file name safe to join onto the save directory:
/// no directories or traversal, no characters Windows rejects, no device names,
/// and short enough for every common filesystem.
pub fn safe_name(raw: &str) -> String {
    let base = raw.rsplit(|c| c == '/' || c == '\\').next().unwrap_or("");
    let cleaned: String = base
        .chars()
        .filter(|c| !c.is_control() && !matches!(c, ':' | '*' | '?' | '"' | '<' | '>' | '|'))
        .collect();
    // Windows silently drops trailing dots and spaces, which would change the name.
    let mut name = cleaned.trim().trim_start_matches('.').trim_end_matches(['.', ' ']).to_owned();

    if name.len() > MAX_NAME_BYTES {
        let ext: String = match name.rfind('.') {
            Some(d) if d > 0 && name.len() - d <= 16 => name[d..].to_owned(),
            _ => String::new(),
        };
        let keep = MAX_NAME_BYTES - ext.len();
        let cut = name.char_indices().map(|(i, _)| i).take_while(|i| *i <= keep).last().unwrap_or(0);
        name = format!("{}{}", &name[..cut], ext);
        name = name.trim_end_matches(['.', ' ']).to_owned();
    }

    let stem = name.split('.').next().unwrap_or("").to_ascii_uppercase();
    if RESERVED.contains(&stem.as_str()) {
        name.insert(0, '_');
    }
    if name.is_empty() { "file".into() } else { name }
}

/// Temporary name for a download in progress: always `<final name>.part`, never a
/// name that could belong to one of the user's own files or to another file in the
/// same batch (`with_extension` would turn both `a.bin` and `a.txt` into `a.part`).
fn part_path(final_path: &Path) -> PathBuf {
    for i in 0.. {
        let mut raw = final_path.as_os_str().to_owned();
        raw.push(if i == 0 { ".part".to_owned() } else { format!(".part{i}") });
        let p = PathBuf::from(raw);
        if !p.exists() { return p; }
    }
    unreachable!()
}

fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let mut p = dir.join(name);
    let mut i = 1;
    while p.exists() {
        let (stem, ext) = match name.rfind('.') {
            Some(d) if d > 0 => (&name[..d], &name[d..]),
            _ => (name, ""),
        };
        p = dir.join(format!("{stem} ({i}){ext}"));
        i += 1;
    }
    p
}

/// Sender side. Returns number of files sent, or Err (incl. rejection).
pub fn send_files<S: Read + Write>(s: &mut S, my_name: &str, files: &[PathBuf],
                                   progress: &mut dyn FnMut(&str, u64, u64)) -> io::Result<usize> {
    let sources = files.iter().map(|p| Source::open(p)).collect::<io::Result<Vec<_>>>()?;
    send_sources(s, my_name, sources, progress)
}

/// Sender side for files that are already open.
pub fn send_sources<S: Read + Write>(s: &mut S, my_name: &str, sources: Vec<Source>,
                                     progress: &mut dyn FnMut(&str, u64, u64)) -> io::Result<usize> {
    let peer = hello(s, my_name)?;
    write_frame(s, &["OFFER", &sources.len().to_string()])?;
    for src in &sources {
        write_frame(s, &["FILE", &src.size.to_string(), &src.name])?;
    }
    let ans = read_frame(s)?;
    if ans[0] != "ACCEPT" {
        // A receiver may say why (no space, unusable folder); a person declining says nothing.
        let msg = match ans.get(1).filter(|r| !r.is_empty()) {
            Some(reason) => format!("{} rejected the transfer: {reason}", peer.name),
            None => format!("{} rejected the transfer", peer.name),
        };
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, msg));
    }
    let n = sources.len();
    for mut src in sources {
        let hash = stream_out(s, &mut src, progress)?;
        write_frame(s, &["END", &hash])?;
        let r = read_frame(s)?;
        if r[0] != "OK" {
            return Err(io::Error::new(io::ErrorKind::InvalidData, format!("receiver error for {}: {}", src.name, r.get(1).cloned().unwrap_or_default())));
        }
    }
    Ok(n)
}

/// Sends one file's bytes. A helper thread reads the disk and hashes while this
/// thread writes to the cable. Returns the SHA-256 of what was sent.
fn stream_out<S: Write>(s: &mut S, src: &mut Source, progress: &mut dyn FnMut(&str, u64, u64)) -> io::Result<String> {
    let size = src.size;
    let (name, file) = (&src.name, &mut src.file);
    std::thread::scope(|sc| {
        let (full_tx, full_rx) = mpsc::sync_channel::<io::Result<(Vec<u8>, usize)>>(PIPELINE);
        let (free_tx, free_rx) = mpsc::channel::<Vec<u8>>();
        for _ in 0..PIPELINE + 1 { let _ = free_tx.send(vec![0u8; CHUNK]); }

        let reader = sc.spawn(move || -> Option<String> {
            let mut hash = Sha256::new();
            let mut left = size;
            while left > 0 {
                // The writer hangs up on error: then there is nothing left to do.
                let mut buf = free_rx.recv().ok()?;
                let want = (left as usize).min(CHUNK);
                let item = loop {
                    match file.read(&mut buf[..want]) {
                        Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                        Err(e) => break Err(e),
                        Ok(0) => break Err(io::Error::new(io::ErrorKind::UnexpectedEof, "file shrank while sending")),
                        Ok(n) => {
                            hash.update(&buf[..n]);
                            left -= n as u64;
                            break Ok((buf, n));
                        }
                    }
                };
                let failed = item.is_err();
                full_tx.send(item).ok()?;
                if failed { return None; }
            }
            Some(hash.finish_hex())
        });

        let mut sent = 0u64;
        while sent < size {
            let (buf, n) = match full_rx.recv() {
                Ok(item) => item?,
                Err(_) => return Err(io::Error::new(io::ErrorKind::Other, "file reader stopped")),
            };
            s.write_all(&buf[..n])?;
            sent += n as u64;
            progress(name, sent, size);
            let _ = free_tx.send(buf);
        }
        drop(free_tx);
        reader.join()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "file reader crashed"))?
            .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "file reader stopped"))
    })
}

/// Receiver side. `accept` decides on the offer (name, size list). Returns saved paths.
pub fn receive_files<S: Read + Write>(s: &mut S, my_name: &str, dir: &Path,
                                      accept: &mut dyn FnMut(&Peer, &[(String, u64)]) -> bool,
                                      progress: &mut dyn FnMut(&str, u64, u64)) -> io::Result<Vec<PathBuf>> {
    let peer = hello(s, my_name)?;
    let f = read_frame(s)?;
    if f[0] != "OFFER" || f.len() < 2 { return Err(io::Error::new(io::ErrorKind::InvalidData, "expected OFFER")); }
    let n: usize = f[1].parse().map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "bad count"))?;
    if n > 10_000 { return Err(io::Error::new(io::ErrorKind::InvalidData, "too many files")); }
    let mut offers = Vec::new();
    for _ in 0..n {
        let f = read_frame(s)?;
        if f[0] != "FILE" || f.len() < 3 { return Err(io::Error::new(io::ErrorKind::InvalidData, "expected FILE")); }
        let size: u64 = f[1].parse().map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "bad size"))?;
        offers.push((safe_name(&f[2]), size));
    }
    // Prepared before asking, so a bad save folder is reported instead of failing mid-transfer.
    if let Err(e) = fs::create_dir_all(dir) {
        write_frame(s, &["REJECT", "cannot use the save folder"])?;
        return Err(io::Error::new(e.kind(), format!("cannot use save folder {}: {e}", dir.display())));
    }
    // Checked before anyone is asked: a transfer that cannot fit would only fail
    // half-way, after the cable was busy for minutes.
    let total: u64 = offers.iter().map(|(_, sz)| *sz).sum();
    if let Some(free) = crate::fsinfo::available_space(dir) {
        if total.saturating_add(SPACE_MARGIN) > free {
            let reason = format!("not enough space: need {}, free {}", human_size(total), human_size(free));
            write_frame(s, &["REJECT", &reason])?;
            return Err(io::Error::new(io::ErrorKind::Other, format!("{} wanted to send {}: {reason}", peer.name, human_size(total))));
        }
    }
    if !accept(&peer, &offers) {
        write_frame(s, &["REJECT"])?;
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "rejected locally"));
    }
    write_frame(s, &["ACCEPT"])?;
    let mut saved = Vec::new();
    for (name, size) in &offers {
        let path = unique_path(dir, name);
        let tmp = part_path(&path);
        let out = File::create(&tmp)?;
        let got_hash = match stream_in(s, out, name, *size, progress) {
            Ok(h) => h,
            Err(e) => { let _ = fs::remove_file(&tmp); return Err(e); }
        };
        let end = read_frame(s)?;
        let want_hash = end.get(1).cloned().unwrap_or_default();
        if end[0] != "END" || want_hash != got_hash {
            let _ = fs::remove_file(&tmp);
            write_frame(s, &["ERR", "checksum mismatch"])?;
            return Err(io::Error::new(io::ErrorKind::InvalidData, format!("checksum mismatch for {name}")));
        }
        fs::rename(&tmp, &path)?;
        write_frame(s, &["OK"])?;
        saved.push(path);
    }
    Ok(saved)
}

/// Receives one file's bytes into `out`. This thread reads the cable while a helper
/// thread hashes and writes to disk. Returns the SHA-256 of what was received.
fn stream_in<S: Read>(s: &mut S, mut out: File, name: &str, size: u64,
                      progress: &mut dyn FnMut(&str, u64, u64)) -> io::Result<String> {
    std::thread::scope(|sc| {
        let (full_tx, full_rx) = mpsc::sync_channel::<(Vec<u8>, usize)>(PIPELINE);
        let (free_tx, free_rx) = mpsc::channel::<Vec<u8>>();
        for _ in 0..PIPELINE + 1 { let _ = free_tx.send(vec![0u8; CHUNK]); }

        let writer = sc.spawn(move || -> io::Result<String> {
            let mut hash = Sha256::new();
            for (buf, n) in full_rx {
                hash.update(&buf[..n]);
                out.write_all(&buf[..n])?;
                let _ = free_tx.send(buf);
            }
            out.flush()?;
            Ok(hash.finish_hex())
        });

        let net: io::Result<()> = (|| {
            let mut got = 0u64;
            while got < size {
                // The writer hangs up when the disk fails; its own error is reported below.
                let Ok(mut buf) = free_rx.recv() else { return Ok(()) };
                let want = ((size - got) as usize).min(CHUNK);
                s.read_exact(&mut buf[..want])?;
                got += want as u64;
                if full_tx.send((buf, want)).is_err() { return Ok(()); }
                progress(name, got, size);
            }
            Ok(())
        })();
        drop(full_tx);
        let disk = writer.join().map_err(|_| io::Error::new(io::ErrorKind::Other, "file writer crashed"))?;
        // A disk error explains a stopped network loop, so it wins; otherwise report the cable.
        let hash = disk?;
        net?;
        Ok(hash)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{TcpListener, TcpStream};

    #[test]
    fn safe_names() {
        assert_eq!(safe_name("../../etc/passwd"), "passwd");
        assert_eq!(safe_name("C:\\Windows\\evil.exe"), "evil.exe");
        assert_eq!(safe_name(".."), "file");
        assert_eq!(safe_name(".hidden"), "hidden");
        // Windows device names and trailing dots
        assert_eq!(safe_name("NUL"), "_NUL");
        assert_eq!(safe_name("con.txt"), "_con.txt");
        assert_eq!(safe_name("report.txt..."), "report.txt");
        assert_eq!(safe_name("a*b?c.txt"), "abc.txt");
        // length cap keeps the extension and valid UTF-8
        let long = safe_name(&("ф".repeat(400) + ".txt"));
        assert!(long.len() <= 150 && long.ends_with(".txt"), "{long}");
        assert!(long.chars().count() > 1);
    }

    #[test]
    fn part_file_never_touches_an_existing_file() {
        let dir = std::env::temp_dir().join(format!("cs-part-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        // a real file of the user's that the old code would have overwritten and moved away
        let victim = dir.join("a.bin.part");
        fs::write(&victim, b"precious").unwrap();
        let p = part_path(&dir.join("a.bin"));
        assert_ne!(p, victim);
        // two files in one batch must not share a temp name
        assert_ne!(part_path(&dir.join("a.bin")), part_path(&dir.join("a.txt")));
        assert_eq!(fs::read(&victim).unwrap(), b"precious");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn offer_too_big_for_the_disk_is_refused_with_a_reason() {
        if crate::fsinfo::available_space(&std::env::temp_dir()).is_none() { return; } // no check on this OS
        let dir = std::env::temp_dir().join(format!("cs-space-{}", std::process::id()));
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let dir2 = dir.clone();
        let t = std::thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            let mut asked = false;
            let r = receive_files(&mut s, "rx", &dir2, &mut |_, _| { asked = true; true }, &mut |_, _, _| {});
            (r.map(|v| v.len()).map_err(|e| e.to_string()), asked)
        });
        // a sender offering 1 EiB, spoken by hand so no such file has to exist
        let mut c = TcpStream::connect(addr).unwrap();
        hello(&mut c, "tx").unwrap();
        write_frame(&mut c, &["OFFER", "1"]).unwrap();
        write_frame(&mut c, &["FILE", &(1u64 << 60).to_string(), "huge.bin"]).unwrap();
        let ans = read_frame(&mut c).unwrap();
        assert_eq!(ans[0], "REJECT");
        assert!(ans.get(1).is_some_and(|r| r.contains("not enough space")), "{ans:?}");
        let (res, asked) = t.join().unwrap();
        assert!(res.unwrap_err().contains("not enough space"));
        assert!(!asked, "the person must not be asked about a transfer that cannot fit");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn loopback_roundtrip() {
        let base = std::env::temp_dir().join(format!("cablesend-test-{}", std::process::id()));
        let src = base.join("src"); let dst = base.join("dst");
        fs::create_dir_all(&src).unwrap();
        let a = src.join("a.bin"); let b = src.join("empty.txt");
        let data: Vec<u8> = (0..3_000_007u32).map(|i| (i % 251) as u8).collect();
        fs::write(&a, &data).unwrap(); fs::write(&b, b"").unwrap();

        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let dst2 = dst.clone();
        let t = std::thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            receive_files(&mut s, "rx", &dst2, &mut |_, _| true, &mut |_, _, _| {}).unwrap()
        });
        let mut c = TcpStream::connect(addr).unwrap();
        assert_eq!(send_files(&mut c, "tx", &[a, b], &mut |_, _, _| {}).unwrap(), 2);
        let saved = t.join().unwrap();
        assert_eq!(fs::read(&saved[0]).unwrap(), data);
        assert_eq!(fs::read(&saved[1]).unwrap().len(), 0);
        let _ = fs::remove_dir_all(&base);
    }
}
