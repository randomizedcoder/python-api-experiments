# Performance summary — raw vs cached path

Load test comparing the two nginx paths that front the same Django `df` endpoint:

- **raw** — `/api/df/`, no caching; every request hits uWSGI → Django (`sleepMs` = 1ms + `df`).
- **cached** — `/cached/api/df/`, tmpfs `uwsgi_cache` (TTL `cacheSeconds` = 10s) with
  stale-while-revalidate; requests are served from the in-RAM cache.

## Test setup

| Item          | Value                                                             |
|---------------|------------------------------------------------------------------|
| Date          | 2026-08-19 16:19 UTC                                              |
| Tool          | `siege 4.1.7` via `nix run .#benchmark` (`--benchmark --time=60S`) |
| Concurrency   | 50 (`--concurrent 50`)                                            |
| Duration      | 60 seconds per path                                               |
| Target        | OCI container (OpenResty + uWSGI + Django) on host loopback `127.0.0.1:8080` |
| Host          | AMD Ryzen Threadripper PRO 3945WX (12C/24T), Linux 7.1.8         |
| Cache warmed  | Yes — one priming request before the cached run                  |

> Run directly against the container on the host loopback (not through the MicroVM) so the numbers
> reflect the app + cache, not the QEMU SLiRP network. Through the VM's host→guest port-forward, both
> paths are capped by SLiRP throughput (~600–750 tx/s) and the cache advantage is hidden — which is
> exactly why `siege-benchmark` is also installed inside the guest (`siege-benchmark --target cached`).

## Results

| Metric                        | Raw (`/api/df/`) | Cached (`/cached/api/df/`) | Improvement |
|-------------------------------|-----------------:|---------------------------:|------------:|
| Transactions (60s)            |           46,087 |                  2,218,388 |      ~48.1× |
| Transaction rate (tx/s)       |           757.14 |                  36,402.82 |      ~48.1× |
| Mean response time (s)        |             0.07 |                       0.00 |     ~≥7× ↓  |
| Throughput (MB/s)             |             0.75 |                      36.21 |      ~48.3× |
| Data transferred (MB)         |            45.84 |                   2,206.59 |      ~48.1× |
| Longest transaction (s)       |             0.08 |                       0.02 |       ~4× ↓ |
| Availability (%)              |           100.00 |                     100.00 |           = |
| Failed transactions           |                0 |                          0 |           = |
| Effective concurrency         |            49.93 |                      46.80 |           ~ |

## Takeaways

- The tmpfs `uwsgi_cache` lifts throughput by roughly **48×** (≈757 → ≈36,400 tx/s) and collapses
  mean response time from ~70ms to effectively 0, because cached requests never touch uWSGI/Django
  or the `df` subprocess + 1ms sleep.
- Both paths held **100% availability with zero failed transactions** at 50 concurrent users.
- The raw path's ceiling (~757 tx/s) is set by the 2 uWSGI worker processes plus the per-request 1ms
  sleep and `df` fork; scaling it would mean more workers, not more nginx.
- Stale-while-revalidate keeps the cached path fast even across TTL boundaries: at expiry the client
  gets the stale body immediately (`X-Cache-Status: STALE`) while nginx refreshes in the background,
  so there is no periodic latency spike from blocking `EXPIRED` refetches.

## Reproduce

```sh
# from the host (against a locally-run container or the VM's forwarded port)
nix run .#benchmark -- --target raw    --concurrent 50
nix run .#benchmark -- --target cached --concurrent 50

# or from inside the MicroVM (bypasses host<->guest network)
siege-benchmark --target raw    --concurrent 50
siege-benchmark --target cached --concurrent 50
```
