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
    build-image      nix build .#oci-webapp && ./result | docker load
    vm-up            Boot the microVM (nix run .#vm)
    bench [args]     siege load test, e.g. `bench --target cached`

    Nix:
      nix build .#django-app        Django app (uWSGI runner)
      nix build .#oci-webapp        OCI image
      nix run   .#vm                Boot the microVM
      nix run   .#benchmark -- --target cached
      nix flake check               python unit tests + nixfmt
    EOF
    }

    run-local() {
      ( cd src && python manage.py runserver 127.0.0.1:8000 )
    }

    run-tests() {
      ( cd src && pytest -q )
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
