//! Parsing of `/proc/self/mountinfo` (pure) + a small cached reader.
//!
//! mountinfo line layout (`man 5 proc`):
//!
//! ```text
//! 36 35 98:0 /root /mount/point rw,opts shared:1 - fstype /dev/src super,opts
//!  0  1   2     3       4          5     6..sep  s  s+1    s+2      s+3
//! ```
//!
//! Field 3 (`major:minor`) is the device id we de-dup on; field 5 is the mount
//! point; after the `-` separator come the fs type and the mount source. Mount
//! point and source may contain octal escapes (`\040` space, `\011` tab, …).

/// A parsed mount entry (only the bits `df` needs).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MountEntry {
    /// Mount source / device name — `df`'s "Filesystem" column.
    pub source: String,
    /// Mount point — `df`'s "Mounted on" column.
    pub mount_point: String,
    /// Filesystem type (e.g. `ext4`, `tmpfs`).
    pub fs_type: String,
    /// `major:minor` device id, used to de-duplicate.
    pub dev_id: String,
}

/// Parse mountinfo text into entries. Unparsable lines are skipped.
pub fn parse_mountinfo(text: &str) -> Vec<MountEntry> {
    let mut out = Vec::new();
    for line in text.lines() {
        if let Some(entry) = parse_line(line) {
            out.push(entry);
        }
    }
    out
}

fn parse_line(line: &str) -> Option<MountEntry> {
    // Split on single spaces; mountinfo never has unescaped spaces between
    // fields, so this is unambiguous.
    let fields: Vec<&str> = line.split(' ').filter(|s| !s.is_empty()).collect();
    if fields.len() < 5 {
        return None;
    }
    let dev_id = fields[2].to_string();
    let mount_point = unescape_octal(fields[4]);

    // Optional fields end at a lone "-"; fs type / source follow it.
    let sep = fields.iter().position(|&f| f == "-")?;
    let fs_type = fields.get(sep + 1)?.to_string();
    let source = unescape_octal(fields.get(sep + 2)?);

    Some(MountEntry {
        source,
        mount_point,
        fs_type,
        dev_id,
    })
}

/// Decode `\NNN` octal escapes (space, tab, newline, backslash) that the kernel
/// uses for special bytes in mount point / source names.
fn unescape_octal(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\\'
            && i + 3 < b.len()
            && b[i + 1..i + 4].iter().all(|c| (b'0'..=b'7').contains(c))
        {
            let code = (b[i + 1] - b'0') * 64 + (b[i + 2] - b'0') * 8 + (b[i + 3] - b'0');
            out.push(code);
            i += 4;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Read `/proc/self/mountinfo` (best-effort; empty string on error).
pub fn read_mountinfo() -> String {
    std::fs::read_to_string("/proc/self/mountinfo").unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_basic_line() {
        let e = parse_line("36 35 8:1 / /data rw,relatime shared:1 - ext4 /dev/sdb1 rw").unwrap();
        assert_eq!(e.dev_id, "8:1");
        assert_eq!(e.mount_point, "/data");
        assert_eq!(e.fs_type, "ext4");
        assert_eq!(e.source, "/dev/sdb1");
    }

    #[test]
    fn parses_line_without_optional_fields() {
        let e = parse_line("22 21 0:20 / /proc rw - proc proc rw").unwrap();
        assert_eq!(e.fs_type, "proc");
        assert_eq!(e.mount_point, "/proc");
    }

    #[test]
    fn skips_malformed() {
        assert!(parse_line("").is_none());
        assert!(parse_line("36 35 8:1 /").is_none());
        assert!(parse_line("36 35 8:1 / /data rw,relatime no-separator ext4").is_none());
    }

    #[test]
    fn decodes_octal_escapes() {
        assert_eq!(unescape_octal("/mnt/a\\040b"), "/mnt/a b");
        assert_eq!(unescape_octal("/x\\011y"), "/x\ty");
        assert_eq!(unescape_octal("/back\\134slash"), "/back\\slash");
        assert_eq!(unescape_octal("/plain"), "/plain");
    }
}
