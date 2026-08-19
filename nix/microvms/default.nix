# nix/microvms/default.nix
#
# MicroVM entry point. Builds the runner that boots the VM (dockerd + BOTH the
# Python and Rust webapp OCI images), with each nginx port forwarded to the
# hypervisor.
#
{
  pkgs,
  lib,
  microvm,
  nixpkgs,
  constants,
  ociImage, # Python (uWSGI+Django) stream script
  ociRustImage, # Rust (monoio) stream script
  siegeBenchmark,
}:

let
  vmConstants = import ./constants.nix;

  containers = [
    {
      name = "webapp";
      image = ociImage;
      imageRef = "webapp:latest";
      port = constants.nginxPort;
      tmpfsDir = "/var/cache/nginx";
      extraArgs = "";
    }
    {
      name = "rust-webapp";
      image = ociRustImage;
      imageRef = "rust-webapp:latest";
      port = constants.rustNginxPort;
      tmpfsDir = constants.rustCacheDir;
      # io_uring: Docker's default seccomp profile blocks io_uring_setup.
      extraArgs = "--security-opt seccomp=unconfined";
    }
  ];

  runner = import ./mkVm.nix {
    inherit
      pkgs
      lib
      microvm
      nixpkgs
      constants
      vmConstants
      containers
      siegeBenchmark
      ;
  };
in
{
  inherit runner;
}
