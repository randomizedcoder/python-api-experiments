#
# flake.nix — python-api-experiments
#
# Thin orchestrator, modeled on ~/Downloads/xtcp2. Every concern lives under
# ./nix/ and is wired up by ./nix/default.nix (the per-system aggregator).
#
# Quick references:
#   nix develop                       # dev shell
#   nix build   .#django-app          # the Django app derivation (uWSGI runner)
#   nix build   .#oci-webapp          # OCI image (load via `./result | docker load`)
#   nix run     .#vm                  # boot the microVM (dockerd runs the image)
#   nix run     .#benchmark -- --target cached   # siege load test
#   nix flake check                   # python unit tests + nixfmt
#
{
  description = "python-api-experiments — Django df-API behind an OpenResty cache in a microVM";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  nixConfig = {
    extra-substituters = [ "https://microvm.cachix.org" ];
    extra-trusted-public-keys = [
      "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys="
    ];
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      microvm,
    }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = nixpkgs.lib;

        aggregator = import ./nix {
          inherit
            pkgs
            lib
            microvm
            nixpkgs
            ;
          src = ./.;
        };
      in
      {
        inherit (aggregator)
          packages
          devShells
          apps
          checks
          ;
      }
    );
}
