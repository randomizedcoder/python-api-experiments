# Performance summary — Python vs Rust `df`-API

Head-to-head load test of the two stacks, each fronting the **same** two nginx paths
(raw `/api/df/`, cached `/cached/api/df/`):

- **Python** — Django under uWSGI (2 worker processes), `uwsgi_pass`, `subprocess df`.
- **Rust** — `rust-df` (monoio/io_uring, thread-per-core), plain HTTP/1.1 over per-worker Unix
  sockets, `statvfs(2)` (no subprocess), async non-blocking `sleep_ms`.

Both impose the identical `sleepMs = 1` delay and emit no cache-control headers (nginx + Lua add them
on the cached path).

## Test setup

| Item          | Value                                                              |
|---------------|-------------------------------------------------------------------|
| Date          | 2026-08-19                                                         |
| Tool          | `siege 4.1.7` via `nix run .#benchmark` (`--benchmark --time=60S`) |
| Concurrency   | 50 (`--concurrent 50`)                                             |
| Duration      | 60 seconds per run                                                 |
| Target        | OCI containers on host loopback (`:8080` Python, `:8081` Rust)     |
| Host          | AMD Ryzen Threadripper PRO 3945WX (12C/24T), Linux 7.1.8           |
| Workers       | Python: 2 uWSGI procs · Rust: 24 (auto = nproc)                    |
| Cache warmed  | Yes — one priming request before each cached run                  |

> Run against the containers on the host loopback (not through the MicroVM): the QEMU SLiRP link caps
> both stacks at a few hundred tx/s and hides the backend difference. That is exactly why
> `siege-benchmark` is also baked into the guest (`siege-benchmark --stack rust --target cached`).

## Results

| Metric (per run)          | Python raw | Rust raw   | Python cached | Rust cached |
|---------------------------|-----------:|-----------:|--------------:|------------:|
| Transactions (60s)        |     42,242 |  1,169,436 |     2,015,549 |   2,099,974 |
| Transaction rate (tx/s)   |     692.83 |  19,240.47 |     33,155.93 |   34,544.73 |
| Mean response time (s)    |       0.07 |       0.00 |          0.00 |        0.00 |
| Throughput (MB/s)         |       0.69 |      12.70 |         32.98 |       22.80 |
| Availability (%)          |     100.00 |     100.00 |        100.00 |      100.00 |
| Failed transactions       |          0 |          0 |             0 |           0 |

## Headline comparisons

- **Raw (uncached) path: Rust ≈ 27.8× Python** (19,240 vs 693 tx/s), and mean response time drops
  from ~70 ms to effectively 0.
- **Cached path: ≈ parity** (Rust 34,545 vs Python 33,156 tx/s, ~1.04×) — expected, since both are
  served from nginx's tmpfs cache and the backend barely matters once warm.
- 100% availability, zero failed transactions across all four runs.

## Why the raw path is so much faster in Rust

1. **Async, non-blocking `sleep`** — the 1 ms delay is a timer yield, so one core keeps serving other
   requests during it. Python's `time.sleep` blocks its worker, so the raw path is capped near
   `2 workers / 1 ms`.
2. **No subprocess** — `statvfs(2)` in-process instead of forking/execing `df` and re-parsing text.
3. **Thread-per-core + io_uring + UDS keepalive** — 24 pinned workers, each its own socket and event
   loop, no GIL, no cross-thread contention.
4. **Minimal allocation / mimalloc / precomputed response frame.**

The cached path shows why the nginx cache matters regardless of backend: it lifts the *Python* raw
path ~48× on its own (see `docs/performance.md`), and here it brings the two backends to parity.

## Caveat (fair comparison)

The raw comparison is not worker-matched: Rust auto-scales to all 24 cores while uWSGI ran 2
processes. That is deliberate — the goal was "as fast as possible" — but the ~28× figure combines the
architecture win (async sleep, no fork) with the higher worker count. Even matched 2-vs-2 the async
sleep alone should keep Rust well ahead on the raw path; matching workers is a possible follow-up.

## Reproduce

```sh
# from the host (containers on :8080 / :8081)
nix run .#benchmark -- --stack python --target raw
nix run .#benchmark -- --stack rust   --target raw
nix run .#benchmark -- --stack python --target cached
nix run .#benchmark -- --stack rust   --target cached

# or from inside the MicroVM (bypasses host<->guest network)
siege-benchmark --stack rust --target raw --concurrent 50
```
