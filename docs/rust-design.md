# Design: high-performance Rust `df`-API behind an OpenResty cache

A Rust reimplementation of the Django `df`-API, built to be as fast as the stack allows while
staying **functionally equivalent** to the Python version. Same two-path nginx caching model
(`docs/design.md`), same JSON shape, same artificial `sleepMs` delay, no cache-control headers from
the app — but a fully async, thread-per-core daemon that nginx reaches over a **Unix domain socket**,
and that computes `df` from **syscalls instead of shelling out**.

## Goals

1. **Functional parity** with the Python app (below), so the two are directly comparable.
2. **Maximum throughput / minimum latency**: full async, thread-per-core, UDS, keepalive, zero-ish
   allocation on the hot path.
3. **Slot into the existing modular flake**: a new Rust crate under `rust/`, new `nix/` modules, its
   own OCI image, and a place in the same MicroVM so Python vs Rust can be benchmarked side by side.

## Functional parity with the Python app

| Aspect | Python (`src/`) | Rust (this design) |
|--------|-----------------|--------------------|
| Endpoint | `GET /api/df/` | `GET /api/df/` (same) |
| Response | `{"filesystems": [ {filesystem, blocks, used, available, use_percent, mounted_on}, … ]}` | identical shape + key names |
| Units | 1K-blocks (GNU `df` default) | 1K-blocks (computed) |
| Delay | `time.sleep(sleepMs/1000)` (blocking) | async timer sleep `sleepMs` (non-blocking) |
| Cache headers from app | none | none (nginx + Lua add them on the cached path) |
| `df` data source | `subprocess.run(["df"])` → `parse_df()` | **`statvfs(2)` per mount from `/proc/self/mountinfo`** — no fork/exec |

The **only intentional behavioural change** is dropping the `df` subprocess in favour of direct
syscalls (the user's explicit request). Everything a client sees is otherwise the same.

## Getting `df` data without shelling out

GNU `df` itself does exactly two things; we do the same, in-process:

1. **Enumerate mounts** by reading `/proc/self/mountinfo` (preferred over `/proc/mounts`: stable
   field layout, unambiguous quoting via octal escapes, gives mount point + fs type + device).
2. **Stat each filesystem** with `statvfs(2)` (via `rustix::fs::statvfs` — raw syscall, no libc, musl
   friendly) to get block counts.

### Value formulas (to match GNU `df` 1K-block output)

For a mount with `statvfs` fields `f_frsize` (fragment size), `f_blocks`, `f_bfree`, `f_bavail`:

```
blocks_1k    = f_blocks * f_frsize / 1024          # "1K-blocks" column
used_1k      = (f_blocks - f_bfree) * f_frsize / 1024
available_1k = f_bavail * f_frsize / 1024          # note: bavail (non-root), like df
use_percent  = 0                        if used_1k + available_1k == 0
               ceil(100 * used / (used + available))  otherwise   # df rounds UP
```

`use_percent` uses the coreutils definition (`used / (used + available)`, **rounded up**), computed
in u128 to avoid overflow on large volumes.

### Filtering (mirror `df`'s default view)

GNU `df` without `-a` hides pseudo/dummy filesystems. We replicate the essentials:

- **Skip `f_blocks == 0`** — drops `proc`, `sysfs`, `cgroup`, `devpts`, etc.
- **Skip dummy fs types** (`autofs`, `mqueue`, `tracefs`, …) — a small allow/deny list.
- **Deduplicate by device id** so bind mounts / the same backing device aren't double-counted
  (df keeps the shortest mount point, matching its behaviour).

### Pure, testable core

Parsing is factored the same way as the Python (`dfapi/df.py`): a pure function

```rust
/// Pure: mountinfo text + a stat closure -> the filesystem rows. No real IO,
/// so it is exercised by table-driven unit tests (statvfs injected as a fn).
pub fn build_rows(mountinfo: &str, stat: impl Fn(&str) -> Option<StatVfs>) -> Vec<Filesystem>
```

`stat` is injected so tests supply canned `StatVfs` values with **no syscalls**. Table-driven cases
(matching the repo's testing style — positive / negative / boundary / corner):

- *positive*: a couple of real ext4/tmpfs mounts → expected rows and computed columns.
- *negative*: empty mountinfo; malformed lines; a mount whose `statvfs` fails (returns `None`) → skipped.
- *boundary*: `use_percent` at 0% and 100%; a 1-block fs; a multi-TB fs (u128 path); `f_bavail` > free.
- *corner*: mount points with **spaces / octal escapes** (`\040`); duplicate device ids; `f_blocks == 0`
  pseudo fs filtered out; root-reserved space (`bfree > bavail`).

## Architecture

```
            (HTTP/1.1 keepalive over Unix domain socket, no TCP)
nginx worker ───────────────────────────────────────────────► rust worker (core N)
   proxy_pass http://rust_df;                                  own UnixListener
   proxy_cache …                                               /run/rustdf/wN.sock
```

- **nginx ⇆ rust over a UDS** — no TCP/IP stack, no 3-way handshake, no Nagle; just a stream socket.
- **Thread-per-core**: at startup the daemon spawns one worker per core, **pins** it with
  `core_affinity`, and each worker owns **its own** `UnixListener` on a **separate socket path**
  (`w0.sock … w{N-1}.sock`). nginx lists all of them in one `upstream {}` and round-robins, so there
  is **zero cross-thread contention** — no shared accept queue, no work-stealing, no locks on the hot
  path. This is the "thread pool ready to answer immediately": the workers are pre-spawned, pinned,
  and blocked in `accept`/`io_uring` from boot.
- **Keepalive**: nginx holds a pool of persistent connections per upstream socket
  (`keepalive 128; proxy_http_version 1.1; proxy_set_header Connection "";`), so under load there is
  effectively no per-request connect/teardown — each request is just read → compute → write on an
  already-open fd.

### Why the async sleep matters (the big win)

The Python `time.sleep(1ms)` **blocks** its uWSGI worker; with 2 workers the raw path tops out around
`2 / 0.001 ≈ 2000 req/s` in theory (~757 measured). In Rust the delay is an **async timer** — the
worker `yield`s for 1ms and services thousands of other in-flight requests meanwhile. One pinned core
can therefore carry enormous concurrency despite the mandatory 1ms, so the raw path should scale far
past the Python ceiling, bounded by CPU and syscall cost rather than by the sleep.

## Runtime & crate choices

**Primary: `monoio` (io_uring, thread-per-core).**

- io_uring batches syscalls (accept/read/write/timeout) and supports **registered fixed buffers** and
  **registered files** for near-zero-overhead IO.
- monoio is *thread-per-core by construction* — no cross-thread futures, no `Send` bound, so per-core
  state (buffers, mount cache) is plain `!Send` local data with no synchronization.
- HTTP/1.1 via `monoio-http`, or a hand-rolled minimal responder (we only need to find request
  boundaries + the path; nginx always sends well-formed requests).

**Fallback: `tokio` (multi-thread) + `hyper` + `hyperlocal` (UDS).** More conventional and battle
tested; still very fast thanks to the async-sleep advantage. Chosen if io_uring is unavailable or if
we want the simpler code path. The crate is structured so the runtime is swappable behind a thin
`serve()` boundary; the pure `df` core is identical either way.

> Kernel note: io_uring needs a reasonably recent kernel; the NixOS MicroVM guest and the host both
> qualify. If we ever target an older kernel, the tokio fallback is the switch.

## Performance optimizations (pulling out the stops)

1. **Thread-per-core + CPU pinning** (`core_affinity`) — no scheduler migration, no work-stealing.
2. **Sharded UDS listeners** (one socket file per worker) — no shared accept queue / lock. (UDS has
   no useful `SO_REUSEPORT` load-balancing, so we shard by path; nginx round-robins the upstream.)
3. **io_uring** (monoio) with **registered fixed buffers** — zero-copy reads/writes, fewer syscalls.
4. **UDS, not TCP** — skip the whole TCP/IP stack between nginx and the app.
5. **HTTP/1.1 keepalive** nginx⇆rust — persistent connections, no per-request connect.
6. **Async, non-blocking `sleepMs`** — the delay never parks a core (see above).
7. **`statvfs` syscall, not `fork`+`exec` of `df`** — removes process spawn, PATH lookup, pipe IO,
   and text re-parsing from every request.
8. **Mount-list cache**: mounts change rarely, so parse `/proc/self/mountinfo` once and refresh only
   when it changes (watch via a cheap periodic re-read or inotify on `/proc/self/mounts`); per request
   we only re-`statvfs` the known set.
9. **Optional lock-free response snapshot** (`arc-swap`): a background task recomputes the full JSON
   at most every `rustSnapshotMs` and publishes an `Arc<Bytes>`; requests just clone the `Arc` and
   write it. Set `rustSnapshotMs = 0` to disable and match the Python's "fresh every request"
   semantics exactly; set it small (e.g. 1–5ms) to amortize `statvfs` under extreme load. Documented
   as a tunable so the parity-vs-speed tradeoff is explicit.
10. **Minimal allocation on the hot path** — per-worker reusable `BytesMut`, `SmallVec` for the row
    list, integers formatted with `itoa` (no `format!`). Optionally `sonic-rs` (SIMD JSON) for
    serialization; pairs well with monoio.
11. **Precomputed response frame** — the constant header bytes (status line, `Content-Type`,
    `Connection: keep-alive`) are a `const`; only `Content-Length` + body vary. Emit header + body with
    a **vectored write** (`writev`) to avoid a copy/concat.
12. **`mimalloc`** as the global allocator — better multithreaded allocation behaviour than the system
    malloc for this churn pattern.
13. **Release build tuning**: `lto = "fat"`, `codegen-units = 1`, `panic = "abort"`, `strip = true`,
    and `target-cpu` set to a portable baseline (`x86-64-v3`) for the container/VM (not `native`, so
    the artifact stays runnable on the VM's vCPU), with `native` allowed only for host-local runs.
14. **Tiny request parse** — `httparse` for the request line + header terminator only; we don't
    materialize headers we don't use.

## Request flow

```
host curl 127.0.0.1:8081                (rust stack listens on rustNginxPort)
      │  qemu SLiRP hostfwd  host 8081 -> guest 8081
      ▼
MicroVM guest :8081  ──►  docker run -p 8081:8081
      ▼
OCI container: OpenResty (nginx + Lua) :8081
      │  proxy_pass http://rust_df  (unix:/run/rustdf/wN.sock, keepalive)
      ▼
rust daemon (thread-per-core, monoio)
      │  async sleep(sleepMs) → read mountinfo (cached) → statvfs each → JSON
      ▼
JsonResponse-equivalent bytes (no cache-control header)
```

## nginx config (Rust variant)

Same two-path model, but `proxy_*` (HTTP upstream) instead of `uwsgi_*`, over UDS with keepalive:

```nginx
upstream rust_df {
    server unix:/run/rustdf/w0.sock;
    server unix:/run/rustdf/w1.sock;
    # … one per worker/core …
    keepalive 128;
}

proxy_cache_path /var/cache/nginx-rust levels=1:2 keys_zone=rust_cache:10m
                 max_size=64m inactive=60s use_temp_path=off;

server {
    listen 8081;

    # RAW — no caching
    location ^~ /api/ {
        proxy_pass http://rust_df;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        add_header X-Cache-Status "BYPASS" always;
    }

    # CACHED — tmpfs proxy_cache + Lua-stamped headers (same as Python stack)
    location ^~ /cached/api/ {
        rewrite ^/cached(/api/.*)$ $1 break;
        proxy_pass http://rust_df;
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        proxy_cache rust_cache;
        proxy_cache_valid 200 ${cacheSeconds}s;
        proxy_cache_key $request_uri;
        proxy_cache_background_update on;
        proxy_cache_use_stale updating error timeout;
        proxy_cache_lock on;

        header_filter_by_lua_block {
            ngx.header["Cache-Control"] =
                "public, max-age=${cacheSeconds}, stale-while-revalidate=${staleWhileRevalidateSeconds}"
            ngx.header["X-Cache-Status"] = ngx.var.upstream_cache_status
        }
    }
}
```

(The Python stack uses `uwsgi_pass`/`uwsgi_cache_*`; the Rust daemon speaks plain HTTP/1.1, so this
uses `proxy_pass`/`proxy_cache_*` — the direct counterparts. Cache TTL, SWR, and Lua headers are
generated from the **same shared constants**, so both stacks behave identically at the cache layer.)

## Constants (added to `nix/constants.nix`)

Reuses `cacheSeconds`, `staleWhileRevalidateSeconds`, `sleepMs`, `cacheMaxSize`, `cacheZoneSize`.
New Rust-specific ones:

| Constant           | Default            | Meaning |
|--------------------|--------------------|---------|
| `rustNginxPort`    | `8081`             | Rust stack's nginx listen / docker `-p` / VM forward (Python stays on 8080) |
| `rustSocketDir`    | `/run/rustdf`      | directory holding the per-worker UDS files |
| `rustWorkers`      | `0` (= all cores)  | worker/core count; `0` means detect `nproc` |
| `rustSnapshotMs`   | `0`                | in-app response snapshot TTL; `0` = fresh per request (Python parity) |

`sleepMs` is shared with the Python app so both impose the identical 1ms delay.

## Module / repo layout

```
rust/
  Cargo.toml                # release profile tuning; deps: monoio, rustix, itoa,
                            #   smallvec, arc-swap, mimalloc, httparse (+ tokio/hyper fallback)
  .cargo/config.toml        # target-cpu, rustflags
  src/
    main.rs                 # arg/env parsing, spawn+pin workers, per-worker listener
    df.rs                   # PURE build_rows() + StatVfs model + formulas + filtering (unit-tested)
    stat.rs                 # thin statvfs wrapper (rustix) + /proc/self/mountinfo reader
    server.rs               # monoio accept loop, minimal HTTP/1.1, async sleep, response framing
    json.rs                 # fast serializer (itoa / sonic-rs) into a reusable buffer
    tests/df_tests.rs       # table-driven pos/neg/boundary/corner (statvfs injected)
nix/
  rust-app.nix              # buildRustPackage/crane build of the daemon (+ musl static option)
  rust-nginx-conf.nix       # generates the proxy_pass/proxy_cache OpenResty config above
  containers/oci-rust-webapp.nix   # nginx + rust daemon in one OCI image (mirrors oci-webapp)
  # aggregator (nix/default.nix): add packages.rust-app, packages.oci-rust-webapp,
  #   apps, and thread the rust image into the MicroVM alongside the Python one.
docs/
  rust-design.md            # this document
```

## Nix build

- Build with **crane** (flake-native, cached incremental) or `rustPlatform.buildRustPackage`, using a
  pinned toolchain via **fenix** so we get a current stable `rustc` with the tuned release profile.
- Prefer a **static musl** build (`x86_64-unknown-linux-musl`) so the OCI image needs almost nothing
  besides the binary + nginx — smallest possible container, no glibc closure for the app.
- The OCI entrypoint mirrors `oci-webapp`: `mkdir` the socket dir + cache dirs, launch the rust daemon
  (it creates `w0.sock … wN.sock`), wait for the sockets, then `exec openresty … daemon off`.

## Running both stacks together

Add the Rust OCI image to the **same MicroVM** as a second container publishing `rustNginxPort`
(8081), with 8081 added to `microvm.forwardPorts` and the guest firewall. Then from the host:

```
curl -i 127.0.0.1:8080/api/df/          # Python (uWSGI)
curl -i 127.0.0.1:8081/api/df/          # Rust
curl -i 127.0.0.1:8081/cached/api/df/   # Rust, cached (MISS→HIT→STALE→HIT)
```

## Testing & verification

- **Unit**: table-driven `df.rs` tests (pure, statvfs injected), run via `cargo test` and wired into
  `nix flake check` as a `rust-tests` check (mirrors the Python `python-tests`).
- **Parity**: assert the Rust JSON has the same keys/structure as the Python response for the same
  mounts; diff a normalized (order-insensitive) view of both `/api/df/` outputs.
- **Cache behaviour**: same as the Python stack — raw = no `Cache-Control` / `BYPASS`; cached =
  `Cache-Control: public, max-age=10, stale-while-revalidate=5`, `MISS→HIT→STALE→HIT`, no `EXPIRED`.
- **Benchmark**: extend `nix/benchmark.nix` with a `--stack python|rust` (or a `--port` already
  suffices) so `siege --benchmark --time=60S` can hit either; produce a `docs/rust-performance.md`
  comparison table (expected: Rust raw path dramatically higher than Python raw, thanks to async
  sleep + no subprocess; cached paths comparable since both are served from nginx RAM).

## Expected wins (hypotheses to confirm with the benchmark)

- **Raw path**: Rust ≫ Python. Python is capped by 2 blocking workers × 1ms; Rust's async sleep +
  per-core concurrency + no `df` fork should lift raw throughput by an order of magnitude or more.
- **Cached path**: roughly equal between stacks — both are served by nginx from tmpfs, so the backend
  barely matters once warm; this validates the cache rather than the backend.
- **Latency**: lower and more consistent tail for Rust (no GIL, no subprocess jitter, pinned cores).

## Decisions

1. **Runtime**: **monoio** (io_uring, thread-per-core) — *decided*. The `serve()` boundary is still
   kept thin so a tokio+hyper fallback could be dropped in, but monoio is the implementation target.
2. **Snapshot cache** (`rustSnapshotMs`): **default `0` — fresh `statvfs` per request** (strict Python
   parity) — *decided*. The `arc-swap` snapshot path is still built and tunable, but off by default;
   we can benchmark a small TTL later as a pure optimization.
3. **Socket sharding** (per-worker paths) vs a single shared listener with `EPOLLEXCLUSIVE`.
   Recommendation: **sharded paths** (simplest zero-contention model, clean nginx upstream).
4. **Filesystem filtering**: how closely to mirror GNU `df`'s dummy-fs list — start minimal
   (`f_blocks == 0` + a short deny list) and expand only if parity diffs show gaps.
```
