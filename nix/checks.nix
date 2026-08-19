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
  # Rust gate: rustfmt --check, clippy (deny warnings), and the table-driven
  # unit + integration tests. Runs hermetically (no rustup in the sandbox).
  rust-tests = pkgs.rustPlatform.buildRustPackage {
    pname = "rust-df-tests";
    version = "0.1.0";
    src = lib.cleanSource (src + "/rust");
    cargoLock.lockFile = src + "/rust/Cargo.lock";
    nativeBuildInputs = [
      pkgs.cmake
      pkgs.gcc
      pkgs.clippy
      pkgs.rustfmt
    ];
    doCheck = true;
    # Enforce formatting + lints before the tests run.
    preCheck = ''
      cargo fmt --check
      cargo clippy --all-targets --release -- -D warnings
    '';
  };

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
