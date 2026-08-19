# nix/microvms/mkVm.nix
#
# Builds the microVM runner (a nixosSystem using the microvm.nix module). The
# VM runs dockerd and, from a shared /nix/store, loads + runs one OCI container
# per entry in `containers`, each publishing its nginx port. Those ports are
# forwarded host -> guest via qemu's SLiRP hostfwd, so from the hypervisor:
#
#   curl 127.0.0.1:8080/api/df/          # Python (uWSGI+Django)
#   curl 127.0.0.1:8081/api/df/          # Rust (monoio)
#   curl 127.0.0.1:8081/cached/api/df/   # Rust, cached
#
# Returns .config.microvm.declaredRunner (provides /bin/microvm-run).
#
{
  pkgs,
  lib,
  microvm,
  nixpkgs,
  constants, # shared app constants (nginxPort, rustNginxPort, cacheMaxSize, ...)
  vmConstants, # ./constants.nix
  containers, # list of { name; image; imageRef; port; tmpfsDir; extraArgs; }
  siegeBenchmark, # siege load-test runner, baked into the guest
}:

let
  # One systemd service per container: load the streamed image from the shared
  # store, then `docker run` it publishing its port with a tmpfs cache dir.
  mkService = c: {
    name = "webapp-${c.name}";
    value = {
      description = "Load and run the ${c.name} OCI image";
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.docker
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 5;
      };
      script = ''
        set -euo pipefail

        # Wait for dockerd.
        for _ in $(seq 1 60); do
          docker info >/dev/null 2>&1 && break
          sleep 1
        done
        docker info >/dev/null 2>&1 || { echo "FATAL: docker not ready"; exit 1; }

        # Load the image straight from the store-shared stream script.
        ${c.image} | docker load

        docker rm -f ${c.name} >/dev/null 2>&1 || true

        exec docker run --rm --name ${c.name} \
          --publish ${toString c.port}:${toString c.port} \
          --tmpfs ${c.tmpfsDir}:size=${constants.cacheMaxSize} \
          ${c.extraArgs} \
          ${c.imageRef}
      '';
    };
  };
in
(nixpkgs.lib.nixosSystem {
  inherit pkgs;
  modules = [
    microvm.nixosModules.microvm
    (
      {
        config,
        pkgs,
        lib,
        ...
      }:
      {
        networking.hostName = vmConstants.hostname;
        system.stateVersion = "24.11";

        microvm = {
          hypervisor = "qemu";
          vcpu = vmConstants.vcpu;
          mem = vmConstants.mem;

          # QEMU SLiRP user-mode networking — required for forwardPorts hostfwd.
          interfaces = [
            {
              type = "user";
              id = "eth0";
              mac = vmConstants.mac;
            }
          ];

          # Host -> guest port forward, one per container. `curl host:<port>` on
          # the hypervisor reaches the guest, where docker -p routes it to nginx.
          forwardPorts = map (c: {
            from = "host";
            host.port = c.port;
            guest.port = c.port;
          }) containers;

          # Real disk for /var/lib/docker (tmpfs root can't hold the images).
          volumes = [
            {
              image = "docker-var.img";
              mountPoint = "/var/lib/docker";
              size = vmConstants.dockerDiskSize;
              fsType = "ext4";
              autoCreate = true;
            }
          ];

          # Share the host store read-only so the images + their closures are
          # available in-guest without a network pull.
          shares = [
            {
              source = "/nix/store";
              mountPoint = "/nix/.ro-store";
              tag = "ro-store";
              proto = "9p";
            }
          ];
        };

        # Bring eth0 up via DHCP (SLiRP hands out 10.0.2.15).
        systemd.network.enable = true;
        networking.useNetworkd = true;
        networking.useDHCP = false;
        systemd.network.networks."20-lan" = {
          matchConfig.MACAddress = vmConstants.mac;
          networkConfig.DHCP = "yes";
        };

        networking.firewall.allowedTCPPorts = map (c: c.port) containers;

        virtualisation.docker = {
          enable = true;
          enableOnBoot = true;
        };

        environment.systemPackages = [
          pkgs.docker
          siegeBenchmark # so you can load-test from inside the guest
        ];

        # One load-and-run service per container.
        systemd.services = builtins.listToAttrs (map mkService containers);
      }
    )
  ];
}).config.microvm.declaredRunner
