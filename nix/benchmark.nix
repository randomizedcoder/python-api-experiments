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
    stack="python"
    host="127.0.0.1"
    port=""
    concurrency="${toString constants.benchConcurrency}"

    usage() {
      cat <<'EOF'
    Usage: siege-benchmark [--stack python|rust] [--target raw|cached] [--host HOST] [--port PORT] [--concurrent N]

      --stack python    hit the Python stack on port ${toString constants.nginxPort}     [default]
      --stack rust      hit the Rust stack   on port ${toString constants.rustNginxPort}
      --target raw      hit /api/df/         (no nginx cache)      [default]
      --target cached   hit /cached/api/df/  (tmpfs nginx cache)
      --host HOST       default 127.0.0.1
      --port PORT       override the stack's default port
      --concurrent N    concurrent users, default ${toString constants.benchConcurrency}

    Runs: siege --benchmark --time=60S --concurrent=N <url>
    EOF
    }

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --stack)      stack="$2"; shift 2 ;;
        --target)     target="$2"; shift 2 ;;
        --host)       host="$2"; shift 2 ;;
        --port)       port="$2"; shift 2 ;;
        --concurrent) concurrency="$2"; shift 2 ;;
        --help|-h)    usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
      esac
    done

    # Default port follows the chosen stack unless --port overrides it.
    if [ -z "$port" ]; then
      case "$stack" in
        python) port="${toString constants.nginxPort}" ;;
        rust)   port="${toString constants.rustNginxPort}" ;;
        *) echo "invalid --stack: $stack (expected python|rust)" >&2; exit 2 ;;
      esac
    fi

    case "$target" in
      raw)    path="/api/df/" ;;
      cached) path="/cached/api/df/" ;;
      *) echo "invalid --target: $target (expected raw|cached)" >&2; exit 2 ;;
    esac

    url="http://$host:$port$path"
    echo "siege benchmark: stack=$stack target=$target url=$url concurrent=$concurrency time=60S"
    echo

    exec siege \
      --benchmark \
      --time=60S \
      --concurrent="$concurrency" \
      "$url"
  '';
}
