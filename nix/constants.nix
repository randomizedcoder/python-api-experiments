# nix/constants.nix
#
# Single source of truth for the app/runtime tunables. Re-imported (parameter-
# free) by django-app.nix, nginx-conf.nix, containers/, benchmark.nix and the
# microvm tree, so a change here propagates everywhere and the nginx cache TTL
# can never drift from the Lua max-age.
#
{
  # nginx uwsgi_cache_valid TTL AND the Lua-injected Cache-Control max-age.
  # README: cache the response for "X seconds", default 10.
  cacheSeconds = 10;

  # Stale-while-revalidate window (seconds). For the cached path, once an entry
  # goes stale nginx serves the stale response immediately and refreshes it in
  # the background, so clients never block on the Django round-trip. Also emitted
  # as the Cache-Control `stale-while-revalidate=N` directive for downstream
  # caches. Default 5.
  staleWhileRevalidateSeconds = 5;

  # Milliseconds the Django view sleeps before responding (README default 1ms).
  sleepMs = 1;

  # OpenResty listen port. Exposed by docker (-p) and forwarded by the microVM
  # (host -> guest) so the hypervisor can curl it directly.
  nginxPort = 8080;

  # uWSGI unix socket, container-internal only (never exposed). nginx reaches
  # Django over the uwsgi protocol via this socket.
  uwsgiSocket = "/run/uwsgi/django.sock";

  # nginx proxy/uwsgi cache sizing.
  cacheMaxSize = "64m"; # on-disk (tmpfs) cache size + docker --tmpfs size
  cacheZoneSize = "10m"; # shared-memory keys zone

  # Default siege concurrency for the benchmark runner (overridable via flag).
  benchConcurrency = 25;
}
