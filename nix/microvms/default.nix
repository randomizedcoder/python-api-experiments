# nix/microvms/default.nix
#
# MicroVM entry point. Builds the runner that boots the VM (dockerd + the
# webapp OCI image), with the nginx port forwarded to the hypervisor.
#
{
  pkgs,
  lib,
  microvm,
  nixpkgs,
  constants,
  ociImage,
  siegeBenchmark,
}:

let
  vmConstants = import ./constants.nix;

  runner = import ./mkVm.nix {
    inherit
      pkgs
      lib
      microvm
      nixpkgs
      constants
      vmConstants
      ociImage
      siegeBenchmark
      ;
  };
in
{
  inherit runner;
}
