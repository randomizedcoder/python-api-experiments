# nix/containers/oci-webapp.nix
#
# The single OCI image: OpenResty (nginx + Lua) + uWSGI + Django in one
# container. Entrypoint starts uWSGI on the internal unix socket, waits for it,
# then execs OpenResty in the foreground.
#
# The nginx cache dir (/var/cache/nginx) is expected to be a tmpfs mount
# supplied at `docker run` time (--tmpfs), so the cache lives in RAM.
#
{
  pkgs,
  lib,
  constants,
  djangoApp,
  nginxConf,
  mkOciImage,
}:

let
  entrypoint = pkgs.writeShellApplication {
    name = "webapp-entrypoint";
    runtimeInputs = [
      djangoApp.app # provides webapp-server (uWSGI + Django)
      pkgs.openresty
      pkgs.coreutils
    ];
    text = ''
      mkdir -p /tmp /var/lib/nginx/logs /var/log/nginx /run/uwsgi /var/cache/nginx

      # Start Django under uWSGI in the background.
      webapp-server &

      # Wait for the uWSGI socket before starting nginx.
      for _ in $(seq 1 100); do
        [ -S "${constants.uwsgiSocket}" ] && break
        sleep 0.1
      done

      exec openresty -p /var/lib/nginx -c ${nginxConf.nginxConf} -g 'daemon off;'
    '';
  };
in
mkOciImage {
  name = "webapp";
  tag = "latest";
  contents = [
    djangoApp.app
    pkgs.openresty
    pkgs.coreutils
    pkgs.bashInteractive
    pkgs.dockerTools.caCertificates
    pkgs.dockerTools.fakeNss # /etc/passwd + /etc/group so nginx getpwnam() works
  ];
  exposedPorts = [ constants.nginxPort ];
  entrypoint = [ "${entrypoint}/bin/webapp-entrypoint" ];
}
