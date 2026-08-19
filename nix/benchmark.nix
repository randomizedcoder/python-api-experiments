# nix/benchmark.nix
#
# siege load-test runner. Hits either the raw (uncached) or the cached path,
# selected via --target, for 60 seconds in benchmark mode.
#
#   nix run .#benchmark -- --target raw
#   nix run .#benchmark -- --target cached
#   nix run .#benchmark -- --target cached --host 127.0.0.1 --port 8080 --concurrent 50
#
# Long-form CLI arguments are used throughout for readability.
#
{
  pkgs,
  lib,
  constants,
}:

pkgs.writeShellApplication {
  name = "siege-benchmark";
  runtimeInputs = [ pkgs.siege ];
  text = ''
    target="raw"
    host="127.0.0.1"
    port="${toString constants.nginxPort}"
    concurrency="${toString constants.benchConcurrency}"

    usage() {
      cat <<'EOF'
    Usage: siege-benchmark [--target raw|cached] [--host HOST] [--port PORT] [--concurrent N]

      --target raw      hit /api/df/         (no nginx cache)      [default]
      --target cached   hit /cached/api/df/  (tmpfs nginx cache)
      --host HOST       default 127.0.0.1
      --port PORT       default ${toString constants.nginxPort}
      --concurrent N    concurrent users, default ${toString constants.benchConcurrency}

    Runs: siege --benchmark --time=60S --concurrent=N <url>
    EOF
    }

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --target)     target="$2"; shift 2 ;;
        --host)       host="$2"; shift 2 ;;
        --port)       port="$2"; shift 2 ;;
        --concurrent) concurrency="$2"; shift 2 ;;
        --help|-h)    usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
      esac
    done

    case "$target" in
      raw)    path="/api/df/" ;;
      cached) path="/cached/api/df/" ;;
      *) echo "invalid --target: $target (expected raw|cached)" >&2; exit 2 ;;
    esac

    url="http://$host:$port$path"
    echo "siege benchmark: target=$target url=$url concurrent=$concurrency time=60S"
    echo

    exec siege \
      --benchmark \
      --time=60S \
      --concurrent="$concurrency" \
      "$url"
  '';
}
