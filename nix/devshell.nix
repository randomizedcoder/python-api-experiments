# nix/devshell.nix
#
# `nix develop` lands here. Everything needed to iterate on the app, the image,
# the microVM and the benchmark.
#
{
  pkgs,
  lib,
  djangoApp,
  constants,
  siegeBenchmark,
}:

pkgs.mkShell {
  name = "python-api-dev";

  packages = [
    djangoApp.testEnv # python + django + pytest + pytest-django
    djangoApp.uwsgi
    siegeBenchmark
    pkgs.docker
    pkgs.qemu_kvm
    pkgs.nixfmt-rfc-style
    pkgs.curl
    pkgs.siege
    # Rust stack toolchain.
    pkgs.cargo
    pkgs.rustc
    pkgs.clippy
    pkgs.rustfmt
    pkgs.cmake
    pkgs.gcc
  ];

  shellHook = ''
    export SLEEP_MS=${toString constants.sleepMs}
    export DJANGO_SETTINGS_MODULE=dfproject.settings

    webapp-help() {
      cat <<'EOF'

    python-api-experiments dev shell
    ================================
    run-local        Run Django dev server on 127.0.0.1:8000 (curl /api/df/)
    run-tests        Run the table-driven pytest suite
    run-rust-local   Build + run the rust-df daemon on a local socket dir
    build-image      nix build .#oci-webapp && ./result | docker load
    vm-up            Boot the microVM (nix run .#vm) — Python :8080 + Rust :8081
    bench [args]     siege load test, e.g. `bench --stack rust --target cached`

    Nix:
      nix build .#django-app        Django app (uWSGI runner)
      nix build .#rust-app          Rust df daemon (monoio)
      nix build .#oci-webapp        Python OCI image
      nix build .#oci-rust-webapp   Rust OCI image
      nix run   .#vm                Boot the microVM (both stacks)
      nix run   .#benchmark -- --stack rust --target cached
      nix flake check               python + rust tests + nixfmt
    EOF
    }

    run-local() {
      ( cd src && python manage.py runserver 127.0.0.1:8000 )
    }

    run-tests() {
      ( cd src && pytest -q )
    }

    run-rust-local() {
      # Short socket dir (AF_UNIX sun_path limit). Ctrl-C to stop.
      local d=/tmp/rustdf-dev
      mkdir -p "$d"
      ( cd rust && cargo build --release ) || return 1
      echo "rust-df on $d/w*.sock — curl --unix-socket $d/w0.sock http://localhost/api/df/"
      RUST_SOCKET_DIR="$d" RUST_WORKERS="''${RUST_WORKERS:-2}" SLEEP_MS="''${SLEEP_MS:-1}" \
        ./rust/target/release/rust-df
    }

    build-image() {
      nix build .#oci-webapp && ./result | docker load
    }

    vm-up() {
      nix run .#vm
    }

    bench() {
      siege-benchmark "$@"
    }

    webapp-help
  '';
}
