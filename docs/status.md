# Implementation status

Tracks progress toward `docs/design.md`. Update as work proceeds.

Legend: `[ ]` todo · `[~]` in progress · `[x]` done

## Steps

- [x] 1. `docs/design.md` — design write-up
- [x] 2. `docs/status.md` — this tracker
- [x] 3. Django project under `src/` (project, app, pure `df.py`, view, urls, wsgi, settings) + table-driven `tests/test_df.py`
- [x] 4. `nix/constants.nix` + thin `flake.nix` + `nix/default.nix` aggregator
- [x] 5. `nix/django-app.nix` (pythonEnv incl. pytest + uWSGI + `bin/webapp-server`) + `nix/checks.nix`
- [x] 6. `nix/nginx-conf.nix` (nginx.conf + uwsgi_params from constants)
- [x] 7. `nix/lib/mkOciImage.nix` + `nix/containers/{default,oci-webapp}.nix`
- [x] 8. `nix/microvms/{constants,default,mkVm}.nix` + wire runner into aggregator
- [x] 9. `nix/benchmark.nix` (siege) + wire `packages.siege-benchmark` / `apps.benchmark`
- [x] 10. `nix/devshell.nix`
- [x] 11. `nix flake check` / `nixfmt` clean

## Verification checklist

- [x] Unit tests pass (`nix flake check` → `python-tests`; all pos/neg/boundary/corner rows)
- [x] Container: `curl -i .../api/df/` → no `Cache-Control`, `X-Cache-Status: BYPASS`
- [x] Container: `curl -i .../cached/api/df/` twice → `Cache-Control: public, max-age=10`, MISS then HIT; new MISS after TTL
- [x] Container: body identical across HITs, changes after TTL
- [x] MicroVM: booted runner, host `curl` to `/api/df/` (BYPASS) and `/cached/api/df/` (MISS→HIT→EXPIRED after 10s) — full path host→VM forwardPorts→docker→nginx→uWSGI→Django confirmed
- [x] Benchmark: `nix run .#benchmark -- --target raw` then `--target cached` (60s each) — 100% availability, 0 failed transactions (~37k each)
- [x] Stale-while-revalidate: cached path shows `Cache-Control: ..., stale-while-revalidate=5`; status sequence MISS→HIT→STALE (served immediately after TTL + background refresh)→HIT, never EXPIRED
- [x] `siege-benchmark` present in the guest closure + on the guest system PATH (run `siege-benchmark --target cached` from inside the VM)

## Notes / open items

- uWSGI python3-plugin packaging: `pkgs.uwsgi.override { plugins = [ "python3" ]; }`, invoked with `--plugins python3 --plugins-dir ${uwsgi}/lib/uwsgi` — confirmed working (Django WSGI app loads).
- MicroVM needs an ext4 `microvm.volumes` disk for `/var/lib/docker` (8 GiB, autoCreate).
- First VM boot needs network only if pulling images; our image is loaded from `/nix/store` (9p) via `<streamLayeredImage> | docker load`, so offline. First run costs a one-time image-load delay before port 8080 answers.
- Benchmark throughput is comparable raw vs cached here because the `df` JSON payload is tiny and Django-under-uWSGI is fast, so both saturate the QEMU SLiRP link. The cache is proven functionally by the MISS→HIT→EXPIRED sequence, not by throughput.
- VM `mem = 2304` (not 2048) to sidestep microvm.nix #171 QEMU 2 GiB boot hang.
