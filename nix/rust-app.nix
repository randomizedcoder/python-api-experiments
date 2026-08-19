# nix/rust-app.nix
#
# Builds the `rust-df` daemon (monoio/io_uring, thread-per-core) from ./rust.
# The committed rust/Cargo.lock makes the crate fetch offline/reproducible.
# `doCheck` runs the table-driven `cargo test` during the build.
#
{
  pkgs,
  lib,
  src,
}:

pkgs.rustPlatform.buildRustPackage {
  pname = "rust-df";
  version = "0.1.0";

  src = lib.cleanSource (src + "/rust");

  cargoLock.lockFile = src + "/rust/Cargo.lock";

  # mimalloc (libmimalloc-sys) compiles C, so it needs a C toolchain + cmake.
  nativeBuildInputs = [
    pkgs.cmake
    pkgs.gcc
  ];

  # Tests (+ fmt + clippy) run in the dedicated `checks.rust-tests` gate, so the
  # package build is just the release binary.
  doCheck = false;

  meta = {
    description = "High-performance async df-API (monoio/io_uring) over a Unix socket";
    mainProgram = "rust-df";
  };
}
