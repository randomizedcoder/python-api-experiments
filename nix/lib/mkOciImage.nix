# nix/lib/mkOciImage.nix
#
# Thin wrapper over pkgs.dockerTools.streamLayeredImage. Load the result with:
#   nix build .#oci-webapp && ./result | docker load
#
{ pkgs, lib }:

{
  name,
  tag ? "latest",
  contents ? [ ],
  exposedPorts ? [ ],
  entrypoint, # list, e.g. [ "${script}/bin/entrypoint" ]
}:

let
  exposedPortsAttr = lib.listToAttrs (
    map (p: {
      name = "${toString p}/tcp";
      value = { };
    }) exposedPorts
  );
in
pkgs.dockerTools.streamLayeredImage {
  inherit name tag contents;
  config = {
    Entrypoint = entrypoint;
    ExposedPorts = exposedPortsAttr;
  };
}
