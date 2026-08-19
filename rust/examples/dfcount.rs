//! Standalone harness for syscall/CPU profiling of the df data-gathering path
//! (no server, no io_uring): read /proc/self/mountinfo + statvfs each mount, N
//! times. Mirrors exactly what `server::Ctx::render_df` does per request, so it
//! is the fair counterpart to Python's `subprocess.run(["df"])` loop.
//!
//!   cargo build --release --example dfcount && ./target/release/examples/dfcount 200

use rust_df::{df, mounts, stat};

fn main() {
    let n: usize = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(100);

    let mut total = 0usize;
    for _ in 0..n {
        let mi = mounts::read_mountinfo();
        let rows = df::build_rows(&mi, stat::statvfs);
        total += rows.len();
    }
    std::hint::black_box(total);
}
