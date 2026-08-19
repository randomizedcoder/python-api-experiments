# nix/checks.nix
#
# `nix flake check` targets:
#   - python-tests : the table-driven pytest suite (runs hermetically)
#   - nixfmt       : verifies all .nix files are formatted
#
{
  pkgs,
  lib,
  djangoApp,
  src,
}:

{
  python-tests =
    pkgs.runCommand "python-tests"
      {
        nativeBuildInputs = [ djangoApp.testEnv ];
      }
      ''
        cp -r ${src}/src ./src
        chmod -R u+w ./src
        cd ./src
        export DJANGO_SETTINGS_MODULE=dfproject.settings
        pytest -q
        touch $out
      '';

  nixfmt =
    pkgs.runCommand "nixfmt-check"
      {
        nativeBuildInputs = [ pkgs.nixfmt-rfc-style ];
      }
      ''
        cd ${src}
        nixfmt --check $(find . -name '*.nix' -not -path './.git/*')
        touch $out
      '';
}
