# nix/containers/oci-rust-webapp.nix
#
# The RUST OCI image: OpenResty (nginx + Lua) in front of the `rust-df` daemon
# (monoio/io_uring, thread-per-core), talking over per-worker Unix sockets.
#
# The entrypoint decides the worker count (RUST_WORKERS or nproc), generates the
# nginx upstream include to match, starts the daemon, waits for every socket,
# then execs OpenResty. The proxy_cache dir is a tmpfs supplied at `docker run`.
#
{
  pkgs,
  lib,
  constants,
  rustApp,
  rustNginxConf,
  mkOciImage,
}:

let
  entrypoint = pkgs.writeShellApplication {
    name = "rust-webapp-entrypoint";
    runtimeInputs = [
      rustApp # provides rust-df
      pkgs.openresty
      pkgs.coreutils # nproc, seq, sleep, mkdir
    ];
    text = ''
      export RUST_SOCKET_DIR="${constants.rustSocketDir}"
      export SLEEP_MS="''${SLEEP_MS:-${toString constants.sleepMs}}"

      mkdir -p /tmp /var/lib/nginx/logs /var/log/nginx \
        "${constants.rustSocketDir}" "${constants.rustCacheDir}"

      # Worker count: honor RUST_WORKERS, else nproc (0 in the constant = auto).
      n="''${RUST_WORKERS:-${toString constants.rustWorkers}}"
      if [ "$n" -eq 0 ]; then n="$(nproc)"; fi
      export RUST_WORKERS="$n"

      # Generate the nginx upstream server list to match the workers.
      {
        i=0
        while [ "$i" -lt "$n" ]; do
          echo "server unix:${constants.rustSocketDir}/w$i.sock;"
          i=$((i + 1))
        done
        echo "keepalive 128;"
      } > "${constants.rustSocketDir}/upstream.conf"

      # Start the daemon (creates w0.sock … w{n-1}.sock).
      rust-df &

      # Wait for every worker socket before starting nginx.
      i=0
      while [ "$i" -lt "$n" ]; do
        for _ in $(seq 1 100); do
          [ -S "${constants.rustSocketDir}/w$i.sock" ] && break
          sleep 0.1
        done
        i=$((i + 1))
      done

      exec openresty -p /var/lib/nginx -c ${rustNginxConf.nginxConf} -g 'daemon off;'
    '';
  };
in
mkOciImage {
  name = "rust-webapp";
  tag = "latest";
  contents = [
    rustApp
    pkgs.openresty
    pkgs.coreutils
    pkgs.bashInteractive
    pkgs.dockerTools.caCertificates
    pkgs.dockerTools.fakeNss # /etc/passwd + /etc/group so nginx getpwnam() works
  ];
  exposedPorts = [ constants.rustNginxPort ];
  entrypoint = [ "${entrypoint}/bin/rust-webapp-entrypoint" ];
}
