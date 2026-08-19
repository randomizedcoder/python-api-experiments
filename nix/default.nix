# nix/default.nix
#
# Per-system aggregator. Imports every focused sub-file and returns the
# attribute set consumed by flake.nix ({ packages, devShells, apps, checks }).
#
{
  pkgs,
  lib,
  microvm,
  nixpkgs,
  src,
}:

let
  constants = import ./constants.nix;

  # The Django app: python env + uWSGI + a bin/webapp-server wrapper.
  djangoApp = import ./django-app.nix {
    inherit
      pkgs
      lib
      constants
      src
      ;
  };

  # Generated nginx.conf + uwsgi_params (OpenResty, with Lua cache headers).
  nginxConf = import ./nginx-conf.nix { inherit pkgs lib constants; };

  # Generated nginx.conf for the Rust stack (proxy_pass/proxy_cache over UDS).
  rustNginxConf = import ./rust-nginx-conf.nix { inherit pkgs lib constants; };

  # The Python (uWSGI+Django) and Rust (monoio) OCI images.
  containers = import ./containers {
    inherit
      pkgs
      lib
      constants
      djangoApp
      nginxConf
      rustApp
      rustNginxConf
      ;
  };
  ociWebapp = containers.oci-webapp;
  ociRustWebapp = containers.oci-rust-webapp;

  # MicroVM runner: dockerd loads + runs the OCI image; port forwarded to host.
  # The siege runner is baked into the guest too, so it can be run from inside
  # the VM (bypassing any host<->guest network overhead).
  microvms = import ./microvms {
    inherit
      pkgs
      lib
      microvm
      nixpkgs
      constants
      siegeBenchmark
      ;
    ociImage = ociWebapp;
    ociRustImage = ociRustWebapp;
  };

  # siege load-test runner (raw vs cached via --target).
  siegeBenchmark = import ./benchmark.nix { inherit pkgs lib constants; };

  # The high-performance Rust df daemon (monoio/io_uring, thread-per-core).
  rustApp = import ./rust-app.nix { inherit pkgs lib src; };

  # nix flake check targets.
  checks = import ./checks.nix {
    inherit
      pkgs
      lib
      djangoApp
      src
      ;
  };

  devshell = import ./devshell.nix {
    inherit
      pkgs
      lib
      djangoApp
      constants
      siegeBenchmark
      ;
  };
in
{
  packages = {
    default = ociWebapp;
    django-app = djangoApp.app;
    oci-webapp = ociWebapp;
    vm = microvms.runner;
    siege-benchmark = siegeBenchmark;
    rust-app = rustApp;
    oci-rust-webapp = ociRustWebapp;
  };

  devShells.default = devshell;

  apps = {
    vm = {
      type = "app";
      program = "${microvms.runner}/bin/microvm-run";
    };
    benchmark = {
      type = "app";
      program = "${siegeBenchmark}/bin/siege-benchmark";
    };
  };

  inherit checks;
}
