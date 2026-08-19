# Rust implementation status

Tracks progress toward `docs/rust-design.md`. Update as work proceeds.

Legend: `[ ]` todo · `[~]` in progress · `[x]` done

## Steps

- [x] 1. `docs/rust-status.md` — this tracker
- [x] 2. `rust/` crate: pure `df.rs` + table-driven tests, then `mounts.rs`, `stat.rs`, `json.rs`, `server.rs`, `main.rs`, `lib.rs`; `Cargo.toml`/`Cargo.lock`/`.cargo`
- [x] 3. `nix/constants.nix` — add rust constants (`rustNginxPort`, `rustSocketDir`, `rustWorkers`, `rustSnapshotMs`, `rustCacheDir`)
- [x] 4. `nix/rust-app.nix` + wire `packages.rust-app` + `checks.rust-tests`
- [x] 5. `nix/rust-nginx-conf.nix` (proxy_pass/proxy_cache over UDS + keepalive + SWR + Lua)
- [x] 6. `nix/containers/oci-rust-webapp.nix` + `containers/default.nix`
- [x] 7. `nix/microvms/*` — run BOTH stacks (python 8080 + rust 8081)
- [x] 8. `nix/benchmark.nix` `--stack`; `nix/devshell.nix` rust tooling
- [x] 9. Full `nix flake check`; boot VM; verify both stacks; `docs/rust-performance.md`

## Verification checklist

- [x] `nix flake check` — `rust-tests` (cargo test/fmt/clippy) + `python-tests` + `nixfmt` green
- [x] Container: `curl -i :8081/api/df/` → JSON, no Cache-Control, `X-Cache-Status: BYPASS`
- [x] Container: `curl -i :8081/cached/api/df/` → `Cache-Control: ..., stale-while-revalidate=5`, MISS→HIT→STALE→HIT
- [x] Parity: `:8080/api/df/` vs `:8081/api/df/` — identical keys, same mount points (modulo each stack's own cache tmpfs)
- [x] MicroVM: both `:8080` (python) and `:8081` (rust) work from the host
- [x] Benchmark: siege python vs rust (raw ~27.8× / cached ~parity); recorded in `docs/rust-performance.md`

## Notes / decisions

- Runtime: **monoio** (io_uring, thread-per-core). `rustSnapshotMs = 0` (fresh statvfs per request).
- Toolchain: nixpkgs stable rust (1.97). fenix only if monoio needs nightly (not expected).
- `panic = "abort"` omitted from the release profile — it conflicts with `cargo test` on stable.
- Docker default seccomp blocks `io_uring_setup`; rust container runs with `--security-opt seccomp=unconfined`.
- Rust emits compact JSON (same structure/keys as the Python `indent=2` output; not byte-identical).
