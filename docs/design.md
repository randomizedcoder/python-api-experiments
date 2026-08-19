# Design: Django `df`-API behind an OpenResty cache, in a MicroVM

## Purpose

Demonstrate caching a Python/Django REST response that emits **no cache-control headers**, by
placing an **nginx (OpenResty, with Lua)** cache in front of it. The whole environment is built with
a **modular Nix flake** (thin `flake.nix` importing everything under `./nix/`), modeled on the
design in `~/Downloads/xtcp2/`, and runs inside a **MicroVM** with **dockerd** running a single
**OCI container**.

## The application

A minimal Django project (`dfproject`) with one app (`dfapi`) exposing a single REST endpoint:

- `GET /api/df/` — sleeps `SLEEP_MS` milliseconds (default **1ms**), shells out to `df`, parses the
  output, and returns it as JSON. It sets **no** `Cache-Control` header.

The `df` output parsing is factored into a **pure function** `dfapi/df.py::parse_df(output)` so it
is deterministic and directly unit-testable (no subprocess/IO). The view is a thin wrapper: sleep →
`subprocess.run(["df"])` → `parse_df` → `JsonResponse`.

## Request flow (headline goal)

From the hypervisor/host, a single `curl` reaches the Django app through four hops:

```
host curl 127.0.0.1:8080
      │  (qemu SLiRP hostfwd: microvm.forwardPorts host 8080 -> guest 8080)
      ▼
MicroVM guest :8080
      │  (docker run -p 8080:8080)
      ▼
OCI container: OpenResty (nginx + Lua) :8080
      │  (uwsgi_pass -> unix:/run/uwsgi/django.sock)
      ▼
uWSGI (uwsgi protocol) -> Django (dfproject.wsgi)
      │
      ▼
df + parse_df -> JsonResponse
```

## Two nginx paths

Both paths hit the **same** Django route (`/api/df/`) over the uwsgi protocol:

| Path                    | Caching | Headers added                                                                     |
|-------------------------|---------|-----------------------------------------------------------------------------------|
| `/api/df/`              | none    | `X-Cache-Status: BYPASS`                                                           |
| `/cached/api/df/`       | tmpfs   | `Cache-Control: public, max-age=<N>, stale-while-revalidate=<S>`, `X-Cache-Status` |

The cached location `rewrite`s `/cached/api/...` back to `/api/...` so `PATH_INFO` reaching Django
is identical for both.

## Cache mechanism (why it is built this way)

Django sends no cache-control headers, so nginx will not cache it on its own. nginx decides whether
a response is cacheable from the **upstream** response, and that decision happens **before** any Lua
`header_filter` runs. Therefore:

- **`uwsgi_cache_valid 200 <N>s`** (a native nginx directive, `<N>` = `cacheSeconds`, default 10)
  does the real work: it forces nginx to cache `200` responses for `N` seconds regardless of missing
  upstream cache headers. The cache zone is stored on a **tmpfs** mount (`/var/cache/nginx`).
- **Lua** (`header_filter_by_lua_block`) then stamps the **client-visible** headers:
  `Cache-Control: public, max-age=<N>` and `X-Cache-Status: $upstream_cache_status` (HIT/MISS/…).

Both the directive TTL and the Lua `max-age` are generated from the **same** Nix constant
(`cacheSeconds`), so they cannot drift. `uwsgi_cache*` directives are the uwsgi-protocol equivalents
of `proxy_cache*`.

### Stale-while-revalidate (non-blocking refresh)

Once an entry passes its `cacheSeconds` TTL it goes *stale*. Rather than blocking the client on a
fresh Django round-trip (which would show as `X-Cache-Status: EXPIRED`), the cached path serves the
stale response **immediately** and refreshes the entry in a **background** subrequest:

- **`uwsgi_cache_background_update on`** — on a stale hit, return the stale body now and fire a
  background request to refresh the cache.
- **`uwsgi_cache_use_stale updating error timeout`** — permit serving stale while an update is in
  flight (`updating`), and also if Django errors or times out.
- **`uwsgi_cache_lock on`** — only one request populates a given key at a time; the rest get stale.
- **Lua** adds `stale-while-revalidate=<S>` (`<S>` = `staleWhileRevalidateSeconds`, default **5**) to
  the client `Cache-Control`, so downstream caches/browsers apply the same SWR window.

Observed status sequence for the cached path: `MISS` → `HIT` (fresh) → `STALE` (first request after
TTL, served immediately + background refresh) → `HIT` (refreshed). No `EXPIRED` (blocking) state.

## nginx ↔ Django wiring (uwsgi protocol)

nginx talks to Django via `uwsgi_pass` to `upstream vms_django { server unix:<socket>; }`, including
the standard `uwsgi_params`, mirroring the user's real production config
(`/etc/nginx/default.d/api.conf`, `location ^~ /api/`). uWSGI runs the Django WSGI app and listens
on a unix socket inside the container.

## Constants (single source of truth)

`nix/constants.nix`:

| Constant                      | Default                  | Used by                                          |
|-------------------------------|--------------------------|--------------------------------------------------|
| `cacheSeconds`                | `10`                     | `uwsgi_cache_valid` + Lua `max-age`              |
| `staleWhileRevalidateSeconds` | `5`                      | Lua `stale-while-revalidate` (SWR window)        |
| `sleepMs`                     | `1`                      | Django sleep before responding                   |
| `nginxPort`                   | `8080`                   | OpenResty listen, docker `-p`, VM forwardPorts   |
| `uwsgiSocket`                 | `/run/uwsgi/django.sock` | uWSGI socket + nginx upstream (container-only)    |
| `cacheMaxSize`                | `64m`                    | cache zone size + `--tmpfs` size                 |
| `cacheZoneSize`               | `10m`                    | cache keys zone                                  |
| `benchConcurrency`            | `25`                     | default siege concurrency                        |

`nix/microvms/constants.nix`: VM `mem` (2304 MiB — avoids the microvm.nix 2 GiB QEMU-hang), `vcpu`,
`hostname`, `serialPort`, `useKvm`, and re-exports `nginxPort`.

## Port map

| Where            | Port | Note                                             |
|------------------|------|--------------------------------------------------|
| host             | 8080 | `curl` target; qemu hostfwd to guest             |
| MicroVM guest    | 8080 | `docker run -p 8080:8080`; firewall-allowed      |
| container nginx  | 8080 | OpenResty `listen`                               |
| container uWSGI  | unix | `/run/uwsgi/django.sock` (never exposed)         |

## Nix module layout

```
flake.nix                 # thin orchestrator (inputs: nixpkgs, flake-utils, microvm)
nix/
  default.nix             # aggregator -> { packages, devShells, apps, checks }
  constants.nix           # shared app/runtime constants
  devshell.nix            # nix develop
  django-app.nix          # pythonEnv + uWSGI + bin/webapp-server
  nginx-conf.nix          # generates nginx.conf + uwsgi_params
  benchmark.nix           # siege load-test writeShellApplication
  checks.nix              # python-tests + nixfmt
  lib/mkOciImage.nix      # wraps dockerTools.streamLayeredImage
  containers/{default,oci-webapp}.nix
  microvms/{constants,default,mkVm}.nix
src/                      # Django project (dfproject + dfapi, df.py, tests)
```

## Testing

Table-driven `pytest` (`@pytest.mark.parametrize`) over `parse_df`, spanning positive / negative /
boundary / corner cases, plus view-level tests (no cache-control header; `SLEEP_MS` honored). Run
hermetically via `nix flake check` (`checks.python-tests`) and via `run-tests` in the dev shell.

## Benchmark

`nix run .#benchmark -- --target raw|cached` runs `siege --benchmark --time=60S` (long-form args)
against the chosen path. Comparing the two runs shows the cache's effect (higher transaction rate /
lower response time on the cached path once warm). `--host` and `--concurrent` are overridable.

The same `siege-benchmark` runner is also baked into the MicroVM guest (`environment.systemPackages`),
so it can be run **from inside the VM** — `siege-benchmark --target cached` — to load-test against
`127.0.0.1:8080` locally and bypass any host↔guest network overhead.

## Verification

See `docs/status.md` for the live checklist. End-to-end: unit tests → Django alone → container
alone (raw vs cached header/HIT-MISS behavior) → full MicroVM `curl` from the host → siege.
