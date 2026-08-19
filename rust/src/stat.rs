//! Thin `statvfs(2)` wrapper via `rustix` (raw syscalls, no libc).

use crate::df::StatVfs;

/// `statvfs` a mount point, mapping to our minimal [`StatVfs`]. Returns `None`
/// if the syscall fails (e.g. the mount vanished) so the caller can skip it.
pub fn statvfs(path: &str) -> Option<StatVfs> {
    let s = rustix::fs::statvfs(path).ok()?;
    Some(StatVfs {
        frsize: s.f_frsize as u64,
        blocks: s.f_blocks as u64,
        bfree: s.f_bfree as u64,
        bavail: s.f_bavail as u64,
    })
}
