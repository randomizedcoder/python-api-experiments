# Resource analysis — Python vs Rust (CPU, memory, syscalls)

Companion to `docs/rust-performance.md` (which covers throughput). This looks at *efficiency*: how
much CPU, memory, and how many syscalls each stack spends. Measured 2026-08-19 on the same host
(AMD Ryzen Threadripper PRO 3945WX, 12C/24T, Linux 7.1.8).

To make CPU and memory a **fair, apples-to-apples** comparison, the Rust daemon was pinned to
`RUST_WORKERS=2` to match Python's 2 uWSGI worker processes (both stacks: nginx + 2 backend workers).

## Summary

| Dimension                         | Python        | Rust         | Python / Rust |
|-----------------------------------|--------------:|-------------:|--------------:|
| Syscalls per `df` request         |         ~284  |         ~30  |     **~9.5×** |
| CPU per request (whole container) |    ~1,753 µs  |     ~116 µs  |    **~15.1×** |
| Idle memory (container)           |     ~61 MiB   |     ~30 MiB  |     **~2.0×** |
| Peak memory under load            |     ~71 MiB   |     ~52 MiB  |      ~1.4×    |
| Throughput @ 2 workers, raw (rps) |        ~761   |     ~10,098  |  ~13.3× (Rust) |

## 1. Syscalls per request

The endpoint's data gathering is the thing that changed: Python **shells out to `df`**, Rust reads
`/proc/self/mountinfo` + `statvfs(2)` **in-process**. Measured with `strace -f -c` using a delta
(200 iterations minus 20, ÷180) so process startup cancels out. Rust was measured with a standalone
`examples/dfcount` harness that runs the exact server data-gathering path (no io_uring), and Python
with a `subprocess.run(["df"])` loop.

- **Python: ~284 syscalls / request** — of which `df`'s *own* work (`statfs` ×27, `openat`,
  `newfstatat`) is only part; the bulk is **subprocess machinery**: `rt_sigaction` ×63 (reset signal
  handlers), exec/PATH lookup + shared-library loading for the `df` binary (`newfstatat` ×46,
  `openat` ×39, `mmap` ×20), plus `vfork`/`execve`/`wait4`/`pipe2`/`dup2`/`close_range`. Every request
  forks a process and loads an executable.
- **Rust: ~30 syscalls / request** — `statfs` ×17 (one per real mount) + a couple of `read`s for
  `/proc/self/mountinfo` + one `openat`/`close`/`statx`. Essentially just the unavoidable filesystem
  stats — the same `statfs` work `df` does internally, without the ~250-syscall subprocess tax.

> The server I/O layer (accept/read/write) is not counted here: Rust uses io_uring, which *batches*
> submissions through `io_uring_enter` (many ops per syscall) and holds keepalive connections, so its
> real per-request I/O syscall count is also very low — but io_uring interacts badly with `strace`, so
> we report the cleanly-measurable data-gathering layer rather than publish unreliable numbers.

## 2. CPU per request

Whole-container CPU (nginx + backend), from cgroup v2 `cpu.stat` `usage_usec` delta across a 30 s
`siege --benchmark --concurrent=25` run on the raw path, ÷ transactions:

- **Python: ~1,753 µs of CPU per request.** The per-request `fork`+`exec` of `df` (load the binary,
  map its libraries, run it, read the pipe) plus the Python/uWSGI request path dominate.
- **Rust: ~116 µs of CPU per request** — ~15× less. No subprocess, no GIL, minimal allocation,
  response written in a single buffer.

At 2 workers this also shows up as throughput: Rust served ~10,098 rps vs Python's ~761 (~13×) on the
raw path, because Python's blocking `time.sleep(1ms)` parks a worker while Rust's async timer does not.

## 3. Memory

Container RSS via `docker stats`:

- **Idle:** Python ~61 MiB vs Rust ~30 MiB (~2×). Python carries the interpreter + Django + 2 uWSGI
  workers; Rust is a single static-ish binary + its 2 worker threads, plus nginx in both.
- **Under load (peak):** Python ~71 MiB vs Rust ~52 MiB. Both grow modestly; Rust stays lighter.

## Why (root causes)

| Cost in Python                                   | How Rust avoids it                                  |
|--------------------------------------------------|-----------------------------------------------------|
| `fork`+`exec` `df` every request (~250 syscalls) | `statvfs(2)` in-process (~30 syscalls total)        |
| Blocking `time.sleep` parks a worker             | async timer — the core keeps serving during the 1ms |
| Interpreter + per-request Python object churn    | compiled, minimal allocation (mimalloc, reused bufs)|
| GIL / process-per-worker for parallelism         | thread-per-core, io_uring, per-worker Unix socket   |

## Method notes / caveats

- Fair-comparison runs use `RUST_WORKERS=2` (matched to uWSGI). With `RUST_WORKERS=0` (auto = 24
  cores) Rust's raw throughput is far higher (see `docs/rust-performance.md`), but CPU-per-request is
  the worker-count-independent efficiency metric and is reported here.
- Syscalls measured via `strace -f -c` delta method (startup cancels). `perf`/tracepoints and
  attaching `strace` to the container PIDs were unavailable (restricted tracefs + `ptrace_scope=1`,
  no root), hence the standalone-harness approach for the data-gathering layer.
- CPU via cgroup v2 `cpu.stat` (`usage_usec`) — whole container, so it includes nginx (identical on
  both sides), which is the honest "cost to serve" number.

### Reproduce

```sh
# syscalls (delta method)
cargo build --release --example dfcount
strace -f -c python3 -c 'import subprocess;[subprocess.run(["df"],capture_output=True) for _ in range(200)]'
strace -c ./rust/target/release/examples/dfcount 200

# CPU + memory (matched workers), per container:
docker run -d --name rsc --security-opt seccomp=unconfined -e RUST_WORKERS=2 -p 8081:8081 \
  --tmpfs /var/cache/nginx-rust:size=64m rust-webapp:latest
#  read /sys/fs/cgroup/cpu.stat usage_usec before/after a 30s siege; docker stats for memory
```
