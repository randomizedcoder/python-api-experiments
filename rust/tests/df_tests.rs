//! Integration-level table-driven tests exercising the public `build_rows` API
//! with an injected `statvfs` (no syscalls). Complements the in-module unit
//! tests in `df.rs` / `mounts.rs`.

use rust_df::df::{build_rows, Filesystem, StatVfs};

struct Case {
    name: &'static str,
    mountinfo: &'static str,
    stats: &'static [(&'static str, StatVfs)],
    expect: fn(&[Filesystem]),
}

const SV_10G: StatVfs = StatVfs {
    frsize: 4096,
    blocks: 2_621_440,
    bfree: 1_310_720,
    bavail: 1_048_576,
};

fn stat_for<'a>(stats: &'a [(&'a str, StatVfs)]) -> impl Fn(&str) -> Option<StatVfs> + 'a {
    move |mp| stats.iter().find(|(p, _)| *p == mp).map(|(_, s)| *s)
}

#[test]
fn table_driven() {
    let cases: &[Case] = &[
        Case {
            name: "positive: single ext4",
            mountinfo: "1 0 8:1 / / rw - ext4 /dev/sda1 rw\n",
            stats: &[("/", SV_10G)],
            expect: |rows| {
                assert_eq!(rows.len(), 1);
                assert_eq!(rows[0].filesystem, "/dev/sda1");
                assert_eq!(rows[0].mounted_on, "/");
                assert_eq!(rows[0].blocks, 10_485_760);
            },
        },
        Case {
            name: "negative: empty input",
            mountinfo: "",
            stats: &[],
            expect: |rows| assert!(rows.is_empty()),
        },
        Case {
            name: "boundary: 100% full",
            mountinfo: "1 0 8:1 / /full rw - ext4 /dev/a rw\n",
            stats: &[(
                "/full",
                StatVfs {
                    frsize: 1024,
                    blocks: 10,
                    bfree: 0,
                    bavail: 0,
                },
            )],
            expect: |rows| {
                assert_eq!(rows.len(), 1);
                assert_eq!(rows[0].use_percent, 100);
            },
        },
        Case {
            name: "corner: space in mount point + pseudo fs filtered",
            mountinfo: "\
1 0 0:1 / /proc rw - proc proc rw
2 0 8:2 / /mnt/a\\040b rw - ext4 /dev/sdb1 rw
",
            stats: &[
                (
                    "/proc",
                    StatVfs {
                        frsize: 4096,
                        blocks: 0,
                        bfree: 0,
                        bavail: 0,
                    },
                ),
                ("/mnt/a b", SV_10G),
            ],
            expect: |rows| {
                assert_eq!(rows.len(), 1);
                assert_eq!(rows[0].mounted_on, "/mnt/a b");
            },
        },
    ];

    for c in cases {
        let rows = build_rows(c.mountinfo, stat_for(c.stats));
        (c.expect)(&rows);
        eprintln!("ok: {}", c.name);
    }
}
