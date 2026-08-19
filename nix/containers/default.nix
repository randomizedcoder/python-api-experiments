# nix/containers/default.nix
#
# Container image assembly. One image: oci-webapp (OpenResty + uWSGI + Django).
#
{
  pkgs,
  lib,
  constants,
  djangoApp,
  nginxConf,
}:

let
  mkOciImage = import ../lib/mkOciImage.nix { inherit pkgs lib; };
in
{
  oci-webapp = import ./oci-webapp.nix {
    inherit
      pkgs
      lib
      constants
      djangoApp
      nginxConf
      mkOciImage
      ;
  };
}
