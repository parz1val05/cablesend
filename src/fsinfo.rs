//! Free disk space, std only (the core has no dependencies, so no `libc` crate).
//!
//! Supported where the system structure layout is fixed and known: Windows and
//! 64-bit Linux / Android. Elsewhere `None`, and the receiver simply skips the check.
use std::path::Path;

/// Bytes available to this process in the filesystem that holds `dir`.
pub fn available_space(dir: &Path) -> Option<u64> {
    imp::available(dir)
}

#[cfg(windows)]
mod imp {
    use std::os::windows::ffi::OsStrExt;
    use std::path::Path;

    #[link(name = "kernel32")]
    extern "system" {
        fn GetDiskFreeSpaceExW(dir: *const u16, free_to_caller: *mut u64, total: *mut u64, total_free: *mut u64) -> i32;
    }

    pub fn available(dir: &Path) -> Option<u64> {
        let wide: Vec<u16> = dir.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
        let (mut free, mut total, mut total_free) = (0u64, 0u64, 0u64);
        // SAFETY: NUL-terminated UTF-16 path and three valid out-pointers.
        let ok = unsafe { GetDiskFreeSpaceExW(wide.as_ptr(), &mut free, &mut total, &mut total_free) };
        (ok != 0).then_some(free)
    }
}

#[cfg(all(any(target_os = "linux", target_os = "android"), target_pointer_width = "64"))]
mod imp {
    use std::ffi::CString;
    use std::os::raw::{c_char, c_int};
    use std::os::unix::ffi::OsStrExt;
    use std::path::Path;

    /// glibc and bionic agree on this layout for 64-bit targets: eleven unsigned
    /// longs followed by six reserved ints. Only the first fields are read.
    #[repr(C)]
    #[allow(dead_code)]
    struct StatVfs {
        f_bsize: u64,
        f_frsize: u64,
        f_blocks: u64,
        f_bfree: u64,
        f_bavail: u64,
        rest: [u64; 6],
        reserved: [u32; 6],
        // headroom, in case a libc ever grows the struct
        _pad: [u64; 8],
    }

    extern "C" {
        fn statvfs(path: *const c_char, buf: *mut StatVfs) -> c_int;
    }

    pub fn available(dir: &Path) -> Option<u64> {
        let c = CString::new(dir.as_os_str().as_bytes()).ok()?;
        let mut st = StatVfs { f_bsize: 0, f_frsize: 0, f_blocks: 0, f_bfree: 0, f_bavail: 0, rest: [0; 6], reserved: [0; 6], _pad: [0; 8] };
        // SAFETY: NUL-terminated path and a buffer at least as large as `struct statvfs`.
        if unsafe { statvfs(c.as_ptr(), &mut st) } != 0 { return None; }
        let unit = if st.f_frsize != 0 { st.f_frsize } else { st.f_bsize };
        let _ = (st.f_blocks, st.f_bfree);
        st.f_bavail.checked_mul(unit)
    }
}

#[cfg(not(any(windows, all(any(target_os = "linux", target_os = "android"), target_pointer_width = "64"))))]
mod imp {
    pub fn available(_dir: &std::path::Path) -> Option<u64> { None }
}

#[cfg(test)]
mod tests {
    #[test]
    fn reports_some_space_for_the_temp_dir() {
        let free = super::available_space(&std::env::temp_dir());
        if cfg!(any(windows, all(target_os = "linux", target_pointer_width = "64"))) {
            let free = free.expect("free space should be known here");
            assert!(free > 0 && free < 1 << 60, "implausible: {free}");
        }
    }
}
