use crate::proto::*;
use crate::sha256::Sha256;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

const CHUNK: usize = 256 * 1024;

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
    let peer = hello(s, my_name)?;
    let mut metas = Vec::new();
    for p in files {
        let md = fs::metadata(p)?;
        if !md.is_file() { return Err(io::Error::new(io::ErrorKind::InvalidInput, format!("not a file: {}", p.display()))); }
        let name = clean_field(&p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default());
        metas.push((p.clone(), name, md.len()));
    }
    write_frame(s, &["OFFER", &metas.len().to_string()])?;
    for (_, name, size) in &metas {
        write_frame(s, &["FILE", &size.to_string(), name])?;
    }
    let ans = read_frame(s)?;
    if ans[0] != "ACCEPT" {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, format!("{} rejected the transfer", peer.name)));
    }
    let mut buf = vec![0u8; CHUNK];
    for (path, name, size) in &metas {
        let mut f = File::open(path)?;
        let mut hash = Sha256::new();
        let mut sent = 0u64;
        while sent < *size {
            let want = ((*size - sent) as usize).min(CHUNK);
            let n = f.read(&mut buf[..want])?;
            if n == 0 { return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "file shrank while sending")); }
            hash.update(&buf[..n]);
            s.write_all(&buf[..n])?;
            sent += n as u64;
            progress(name, sent, *size);
        }
        write_frame(s, &["END", &hash.finish_hex()])?;
        let r = read_frame(s)?;
        if r[0] != "OK" {
            return Err(io::Error::new(io::ErrorKind::InvalidData, format!("receiver error for {name}: {}", r.get(1).cloned().unwrap_or_default())));
        }
    }
    Ok(metas.len())
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
        write_frame(s, &["REJECT"])?;
        return Err(io::Error::new(e.kind(), format!("cannot use save folder {}: {e}", dir.display())));
    }
    if !accept(&peer, &offers) {
        write_frame(s, &["REJECT"])?;
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "rejected locally"));
    }
    write_frame(s, &["ACCEPT"])?;
    let mut saved = Vec::new();
    let mut buf = vec![0u8; CHUNK];
    for (name, size) in &offers {
        let path = unique_path(dir, name);
        let tmp = part_path(&path);
        let mut out = File::create(&tmp)?;
        let mut hash = Sha256::new();
        let mut got = 0u64;
        while got < *size {
            let want = ((*size - got) as usize).min(CHUNK);
            s.read_exact(&mut buf[..want])?;
            hash.update(&buf[..want]);
            out.write_all(&buf[..want])?;
            got += want as u64;
            progress(name, got, *size);
        }
        out.flush()?;
        drop(out);
        let end = read_frame(s)?;
        let want_hash = end.get(1).cloned().unwrap_or_default();
        if end[0] != "END" || want_hash != hash.finish_hex() {
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
    fn loopback_roundtrip() {
        let base = std::env::temp_dir().join(format!("cablesend-test-{}", std::process::id()));
        let src = base.join("src"); let dst = base.join("dst");
        fs::create_dir_all(&src).unwrap();
        let a = src.join("a.bin"); let b = src.join("empty.txt");
        let data: Vec<u8> = (0..1_000_003u32).map(|i| (i % 251) as u8).collect();
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
