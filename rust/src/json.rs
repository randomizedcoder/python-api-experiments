//! Response serialization into a reusable byte buffer.
//!
//! Emits `{"filesystems": [ … ]}` with the same keys/shape as the Python app
//! (compact rather than pretty-printed — same structure, fewer bytes).

use serde::Serialize;

use crate::df::Filesystem;

#[derive(Serialize)]
struct Response<'a> {
    filesystems: &'a [Filesystem],
}

/// Serialize `rows` as JSON into `buf` (cleared first).
pub fn serialize(rows: &[Filesystem], buf: &mut Vec<u8>) {
    buf.clear();
    serde_json::to_writer(&mut *buf, &Response { filesystems: rows })
        .expect("serializing df rows to JSON cannot fail");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wraps_in_filesystems_key() {
        let rows = vec![Filesystem {
            filesystem: "/dev/sda1".into(),
            blocks: 100,
            used: 40,
            available: 60,
            use_percent: 40,
            mounted_on: "/".into(),
        }];
        let mut buf = Vec::new();
        serialize(&rows, &mut buf);
        let s = String::from_utf8(buf).unwrap();
        assert_eq!(
            s,
            r#"{"filesystems":[{"filesystem":"/dev/sda1","blocks":100,"used":40,"available":60,"use_percent":40,"mounted_on":"/"}]}"#
        );
    }

    #[test]
    fn empty_rows() {
        let mut buf = Vec::new();
        serialize(&[], &mut buf);
        assert_eq!(String::from_utf8(buf).unwrap(), r#"{"filesystems":[]}"#);
    }
}
