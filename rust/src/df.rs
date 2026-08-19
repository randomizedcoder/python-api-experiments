//! Pure `df` computation: mount table + `statvfs` results -> filesystem rows.
//!
//! This module has **no real IO** — `build_rows` takes the raw
//! `/proc/self/mountinfo` text and a `stat` closure, so it is exercised
//! directly by table-driven unit tests with canned `StatVfs` values. It mirrors
//! the pure-core split of the Python app (`src/dfapi/df.py::parse_df`).

use serde::Serialize;
use std::collections::HashMap;

use crate::mounts::{parse_mountinfo, MountEntry};

/// The subset of `statvfs(3)` we need, in native units.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StatVfs {
    /// Fragment size (`f_frsize`) in bytes — the unit of the block counts below.
    pub frsize: u64,
    /// Total data blocks (`f_blocks`).
    pub blocks: u64,
    /// Free blocks (`f_bfree`).
    pub bfree: u64,
    /// Free blocks available to unprivileged users (`f_bavail`).
    pub bavail: u64,
}

/// One response row. Field order matches the Python JSON exactly.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Filesystem {
    pub filesystem: String,
    pub blocks: u64,
    pub used: u64,
    pub available: u64,
    pub use_percent: u64,
    pub mounted_on: String,
}

/// Build the per-filesystem rows from mountinfo text + a `statvfs` provider.
///
/// Mirrors GNU `df`'s default view: skips pseudo filesystems (`blocks == 0`)
/// and a small deny-list of dummy fs types, and de-duplicates by device id
/// (keeping the shortest mount point). All arithmetic is in 1K-blocks.
pub fn build_rows(mountinfo: &str, stat: impl Fn(&str) -> Option<StatVfs>) -> Vec<Filesystem> {
    // De-dup by device id, preferring the shortest mount point (matches df).
    let mut by_dev: HashMap<String, MountEntry> = HashMap::new();
    let mut order: Vec<String> = Vec::new();

    for e in parse_mountinfo(mountinfo) {
        if is_dummy_fs(&e.fs_type) {
            continue;
        }
        match by_dev.get(&e.dev_id) {
            Some(existing) if existing.mount_point.len() <= e.mount_point.len() => {}
            Some(_) => {
                by_dev.insert(e.dev_id.clone(), e);
            }
            None => {
                order.push(e.dev_id.clone());
                by_dev.insert(e.dev_id.clone(), e);
            }
        }
    }

    let mut rows = Vec::with_capacity(order.len());
    for dev in order {
        let e = &by_dev[&dev];
        let sv = match stat(&e.mount_point) {
            Some(s) => s,
            None => continue, // mount vanished / not statable -> skip, like df
        };
        if sv.blocks == 0 {
            continue; // pseudo filesystem (proc, sysfs, cgroup, …)
        }
        rows.push(compute_row(e, &sv));
    }
    rows
}

fn compute_row(e: &MountEntry, sv: &StatVfs) -> Filesystem {
    let frsize = sv.frsize.max(1);
    let blocks = sv.blocks.saturating_mul(frsize) / 1024;
    let used = sv.blocks.saturating_sub(sv.bfree).saturating_mul(frsize) / 1024;
    let available = sv.bavail.saturating_mul(frsize) / 1024;
    Filesystem {
        filesystem: e.source.clone(),
        blocks,
        used,
        available,
        use_percent: use_percent(used, available),
        mounted_on: e.mount_point.clone(),
    }
}

/// GNU `df` `Use%`: `ceil(100 * used / (used + available))`, and `0` when the
/// denominator is `0`. Computed in `u128` to avoid overflow on huge volumes.
fn use_percent(used: u64, available: u64) -> u64 {
    let denom = used as u128 + available as u128;
    if denom == 0 {
        return 0;
    }
    let num = 100u128 * used as u128;
    num.div_ceil(denom) as u64
}

/// Dummy / pseudo filesystem types `df` hides by default. Most of these also
/// report `blocks == 0` (so they'd be filtered anyway); this is belt-and-braces.
fn is_dummy_fs(fs_type: &str) -> bool {
    matches!(
        fs_type,
        "autofs"
            | "proc"
            | "sysfs"
            | "devpts"
            | "cgroup"
            | "cgroup2"
            | "mqueue"
            | "debugfs"
            | "tracefs"
            | "securityfs"
            | "pstore"
            | "bpf"
            | "configfs"
            | "fusectl"
            | "hugetlbfs"
            | "devtmpfs"
            | "binfmt_misc"
            | "rpc_pipefs"
            | "nsfs"
            | "selinuxfs"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    // A tiny stat provider driven by a lookup table, so tests do no syscalls.
    fn stat_from<'a>(table: &'a [(&'a str, StatVfs)]) -> impl Fn(&str) -> Option<StatVfs> + 'a {
        move |mp: &str| table.iter().find(|(p, _)| *p == mp).map(|(_, s)| *s)
    }

    const EXT4: StatVfs = StatVfs {
        frsize: 4096,
        blocks: 2_621_440, // 10 GiB / 4KiB
        bfree: 1_310_720,
        bavail: 1_048_576,
    };

    #[test]
    fn positive_basic_mounts() {
        // Two real filesystems on distinct devices.
        let mi = "\
36 35 8:1 / / rw,relatime - ext4 /dev/sda1 rw
40 36 0:30 / /data rw,relatime - ext4 /dev/sdb1 rw
";
        let table = [("/", EXT4), ("/data", EXT4)];
        let rows = build_rows(mi, stat_from(&table));
        assert_eq!(rows.len(), 2);
        let root = &rows[0];
        assert_eq!(root.filesystem, "/dev/sda1");
        assert_eq!(root.mounted_on, "/");
        // 10 GiB total in 1K-blocks = 2_621_440 * 4096 / 1024 = 10_485_760
        assert_eq!(root.blocks, 10_485_760);
        assert_eq!(root.used, (2_621_440 - 1_310_720) * 4096 / 1024);
        assert_eq!(root.available, 1_048_576 * 4096 / 1024);
    }

    #[test]
    fn negative_empty_and_garbage() {
        let table: [(&str, StatVfs); 0] = [];
        assert!(build_rows("", stat_from(&table)).is_empty());
        assert!(build_rows("not a mountinfo line\n???\n", stat_from(&table)).is_empty());
    }

    #[test]
    fn negative_stat_failure_is_skipped() {
        let mi = "36 35 8:1 / / rw - ext4 /dev/sda1 rw\n";
        let table: [(&str, StatVfs); 0] = []; // stat returns None for "/"
        assert!(build_rows(mi, stat_from(&table)).is_empty());
    }

    #[test]
    fn boundary_use_percent_zero_and_full() {
        // Empty disk -> 0%
        let empty = StatVfs {
            frsize: 1024,
            blocks: 100,
            bfree: 100,
            bavail: 100,
        };
        // Full disk -> 100%
        let full = StatVfs {
            frsize: 1024,
            blocks: 100,
            bfree: 0,
            bavail: 0,
        };
        let mi = "\
1 0 8:1 / /empty rw - ext4 /dev/a rw
2 0 8:2 / /full rw - ext4 /dev/b rw
";
        let table = [("/empty", empty), ("/full", full)];
        let rows = build_rows(mi, stat_from(&table));
        let by_mp = |mp: &str| rows.iter().find(|r| r.mounted_on == mp).unwrap();
        assert_eq!(by_mp("/empty").use_percent, 0);
        assert_eq!(by_mp("/full").use_percent, 100);
    }

    #[test]
    fn boundary_use_percent_rounds_up() {
        // used=1, avail=99 -> 1/100 = 1% exactly; used=1, avail=100 -> 0.99% -> ceil 1%
        let a = StatVfs {
            frsize: 1024,
            blocks: 101,
            bfree: 100,
            bavail: 100,
        }; // used=1,avail=100
        let mi = "1 0 8:1 / /a rw - ext4 /dev/a rw\n";
        let table = [("/a", a)];
        let rows = build_rows(mi, stat_from(&table));
        assert_eq!(rows[0].used, 1);
        assert_eq!(rows[0].available, 100);
        assert_eq!(rows[0].use_percent, 1); // ceil(100*1/101)=ceil(0.99)=1
    }

    #[test]
    fn boundary_large_volume_no_overflow() {
        // ~16 EiB worth of blocks; must not overflow (u128 math).
        let huge = StatVfs {
            frsize: 4096,
            blocks: u64::MAX / 4096,
            bfree: 0,
            bavail: 0,
        };
        let mi = "1 0 8:1 / /huge rw - xfs /dev/huge rw\n";
        let table = [("/huge", huge)];
        let rows = build_rows(mi, stat_from(&table));
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].use_percent, 100);
    }

    #[test]
    fn corner_mount_point_with_octal_space() {
        // "/mnt/with space" is encoded as /mnt/with\040space in mountinfo.
        let sv = EXT4;
        let mi = "42 36 8:3 / /mnt/with\\040space rw - ext4 /dev/sdc1 rw\n";
        let table = [("/mnt/with space", sv)];
        let rows = build_rows(mi, stat_from(&table));
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].mounted_on, "/mnt/with space");
    }

    #[test]
    fn corner_dedup_by_device_keeps_shortest_mount() {
        // Same device id on "/" and a longer bind mount -> keep "/".
        let mi = "\
1 0 8:1 / /mnt/bind/deep rw - ext4 /dev/sda1 rw
2 0 8:1 / / rw - ext4 /dev/sda1 rw
";
        let table = [("/", EXT4), ("/mnt/bind/deep", EXT4)];
        let rows = build_rows(mi, stat_from(&table));
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].mounted_on, "/");
    }

    #[test]
    fn corner_pseudo_and_dummy_filtered() {
        let mi = "\
1 0 0:1 / /proc rw - proc proc rw
2 0 0:2 / /sys rw - sysfs sysfs rw
3 0 8:1 / / rw - ext4 /dev/sda1 rw
";
        // proc/sysfs report blocks==0; also on the dummy deny-list.
        let zero = StatVfs {
            frsize: 4096,
            blocks: 0,
            bfree: 0,
            bavail: 0,
        };
        let table = [("/proc", zero), ("/sys", zero), ("/", EXT4)];
        let rows = build_rows(mi, stat_from(&table));
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].mounted_on, "/");
    }
}
