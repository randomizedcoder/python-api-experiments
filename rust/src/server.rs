//! monoio (io_uring, thread-per-core) HTTP/1.1 server over a Unix socket.
//!
//! Each worker owns its own [`monoio`] runtime and its own `UnixListener` on a
//! dedicated socket path (`<dir>/w<idx>.sock`), so there is no cross-thread
//! contention — nginx round-robins across the per-worker sockets. Connections
//! are HTTP/1.1 keep-alive; the artificial `sleep_ms` delay is an async timer,
//! so it never parks the core.

use std::cell::RefCell;
use std::os::unix::fs::PermissionsExt;
use std::rc::Rc;
use std::time::{Duration, Instant};

use monoio::io::{AsyncReadRent, AsyncWriteRentExt};
use monoio::net::{UnixListener, UnixStream};

use crate::{df, json, mounts, stat};

const READ_CHUNK: usize = 8 * 1024;
const MAX_HEAD: usize = 64 * 1024;

/// Per-worker state (single-threaded, so plain `RefCell` is fine).
struct Ctx {
    sleep: Duration,
    mounts: RefCell<MountCache>,
}

struct MountCache {
    text: String,
    at: Instant,
}

impl Ctx {
    fn new(sleep_ms: u64) -> Self {
        Ctx {
            sleep: Duration::from_millis(sleep_ms),
            mounts: RefCell::new(MountCache {
                text: mounts::read_mountinfo(),
                at: Instant::now(),
            }),
        }
    }

    /// The mount list changes rarely, so re-read `/proc/self/mountinfo` at most
    /// once a second; the *numbers* stay fresh via a per-request `statvfs`.
    fn with_mounts<R>(&self, f: impl FnOnce(&str) -> R) -> R {
        let mut c = self.mounts.borrow_mut();
        if c.at.elapsed() >= Duration::from_secs(1) {
            c.text = mounts::read_mountinfo();
            c.at = Instant::now();
        }
        f(&c.text)
    }

    /// Compute the JSON body for the df endpoint (fresh statvfs per request).
    fn render_df(&self) -> Vec<u8> {
        let rows = self.with_mounts(|mi| df::build_rows(mi, stat::statvfs));
        let mut buf = Vec::with_capacity(4096);
        json::serialize(&rows, &mut buf);
        buf
    }
}

/// Run one worker: build a monoio runtime, bind the socket, accept forever.
pub fn run_worker(idx: usize, socket_dir: &str, sleep_ms: u64) {
    let path = format!("{socket_dir}/w{idx}.sock");
    let _ = std::fs::remove_file(&path); // clear a stale socket from a prior run

    let mut rt = monoio::RuntimeBuilder::<monoio::IoUringDriver>::new()
        .enable_timer()
        .build()
        .expect("build monoio io_uring runtime");

    rt.block_on(async move {
        // Bind synchronously with std (universally supported), then hand the fd
        // to monoio. Avoids io_uring's newer bind opcode, which some kernels
        // don't implement.
        let std_listener =
            std::os::unix::net::UnixListener::bind(&path).expect("std bind unix listener");
        // World-writable so nginx (whatever user) can connect.
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666));
        let listener = UnixListener::from_std(std_listener).expect("wrap std unix listener");

        let ctx = Rc::new(Ctx::new(sleep_ms));
        while let Ok((stream, _)) = listener.accept().await {
            let ctx = ctx.clone();
            monoio::spawn(async move {
                serve_conn(stream, ctx).await;
            });
        }
    });
}

async fn serve_conn(mut stream: UnixStream, ctx: Rc<Ctx>) {
    let mut pending: Vec<u8> = Vec::with_capacity(READ_CHUNK);

    loop {
        // Read until we have a complete request head (ending in CRLFCRLF).
        let head_end = loop {
            if let Some(pos) = find_head_end(&pending) {
                break pos;
            }
            if pending.len() > MAX_HEAD {
                return; // oversized head -> drop the connection
            }
            let buf = Vec::with_capacity(READ_CHUNK);
            let (res, buf) = stream.read(buf).await;
            match res {
                Ok(0) => return, // peer closed
                Ok(n) => pending.extend_from_slice(&buf[..n]),
                Err(_) => return,
            }
        };

        // Parse just enough: the path and whether to keep the connection alive.
        let (is_df, keep_alive) = {
            let mut headers = [httparse::EMPTY_HEADER; 32];
            let mut req = httparse::Request::new(&mut headers);
            match req.parse(&pending[..head_end]) {
                Ok(_) => {
                    let is_df = req.path.is_some_and(|p| p.starts_with("/api/"));
                    let keep_alive = !header_has(&req, "connection", "close");
                    (is_df, keep_alive)
                }
                Err(_) => return,
            }
        };

        // GET has no body: the request ends at the head. Drop it (keep any
        // pipelined bytes that follow for the next iteration).
        pending.drain(..head_end);

        let response = if is_df {
            if !ctx.sleep.is_zero() {
                monoio::time::sleep(ctx.sleep).await;
            }
            let body = ctx.render_df();
            frame(b"200 OK", b"application/json", &body, keep_alive)
        } else {
            frame(b"404 Not Found", b"text/plain", b"not found\n", keep_alive)
        };

        let (res, _) = stream.write_all(response).await;
        if res.is_err() || !keep_alive {
            return;
        }
    }
}

/// Offset just past the end of the request head (`\r\n\r\n`), if present.
fn find_head_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n").map(|p| p + 4)
}

/// Case-insensitive check that a header equals a value (used for `Connection`).
fn header_has(req: &httparse::Request, name: &str, value: &str) -> bool {
    req.headers.iter().any(|h| {
        h.name.eq_ignore_ascii_case(name)
            && std::str::from_utf8(h.value).is_ok_and(|v| v.eq_ignore_ascii_case(value))
    })
}

/// Build a complete HTTP/1.1 response (status line + headers + body) in one
/// buffer, so it goes out in a single write. No `Cache-Control` header — nginx
/// + Lua add caching headers on the cached path, mirroring the Python app.
fn frame(status: &[u8], content_type: &[u8], body: &[u8], keep_alive: bool) -> Vec<u8> {
    let conn: &[u8] = if keep_alive { b"keep-alive" } else { b"close" };
    let mut len = itoa::Buffer::new();
    let len = len.format(body.len());

    let mut v = Vec::with_capacity(body.len() + 128);
    v.extend_from_slice(b"HTTP/1.1 ");
    v.extend_from_slice(status);
    v.extend_from_slice(b"\r\nContent-Type: ");
    v.extend_from_slice(content_type);
    v.extend_from_slice(b"\r\nContent-Length: ");
    v.extend_from_slice(len.as_bytes());
    v.extend_from_slice(b"\r\nConnection: ");
    v.extend_from_slice(conn);
    v.extend_from_slice(b"\r\n\r\n");
    v.extend_from_slice(body);
    v
}
