//! High-performance Rust `df`-API — library crate.
//!
//! Functionally equivalent to the Python/Django app (`GET /api/df/` returning
//! `{"filesystems": […]}` after a `sleep_ms` delay, no cache-control headers),
//! but async, thread-per-core (monoio/io_uring), served over a Unix socket, and
//! computing `df` from `statvfs(2)` instead of shelling out. See
//! `docs/rust-design.md`.

pub mod df;
pub mod json;
pub mod mounts;
pub mod server;
pub mod stat;

/// Runtime configuration, resolved from the environment (defaults injected by
/// Nix from `nix/constants.nix`).
pub struct Config {
    pub socket_dir: String,
    pub sleep_ms: u64,
    pub workers: usize,
}

impl Config {
    pub fn from_env() -> Self {
        let socket_dir = env_or("RUST_SOCKET_DIR", "/run/rustdf");
        let sleep_ms = env_or("SLEEP_MS", "1").parse().unwrap_or(1);
        let workers = {
            let w: usize = env_or("RUST_WORKERS", "0").parse().unwrap_or(0);
            if w == 0 {
                std::thread::available_parallelism()
                    .map(|n| n.get())
                    .unwrap_or(1)
            } else {
                w
            }
        };
        Config {
            socket_dir,
            sleep_ms,
            workers,
        }
    }
}

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

/// Spawn and pin one worker per configured core; block until they all exit.
pub fn run(cfg: Config) {
    std::fs::create_dir_all(&cfg.socket_dir).ok();

    let cores = core_affinity::get_core_ids().unwrap_or_default();
    let ncores = cores.len().max(1);

    eprintln!(
        "rust-df: {} worker(s), socket_dir={}, sleep_ms={}",
        cfg.workers, cfg.socket_dir, cfg.sleep_ms
    );

    let mut handles = Vec::with_capacity(cfg.workers);
    for idx in 0..cfg.workers {
        let dir = cfg.socket_dir.clone();
        let sleep_ms = cfg.sleep_ms;
        let core = cores.get(idx % ncores).copied();
        handles.push(std::thread::spawn(move || {
            if let Some(c) = core {
                core_affinity::set_for_current(c);
            }
            server::run_worker(idx, &dir, sleep_ms);
        }));
    }
    for h in handles {
        let _ = h.join();
    }
}
