# nix/microvms/mkVm.nix
#
# Builds the microVM runner (a nixosSystem using the microvm.nix module). The
# VM runs dockerd, loads the OCI image from the shared /nix/store, and runs it
# publishing the nginx port. That port is forwarded host -> guest via qemu's
# SLiRP hostfwd, so from the hypervisor:
#
#   curl 127.0.0.1:${nginxPort}/api/df/          # raw
#   curl 127.0.0.1:${nginxPort}/cached/api/df/   # cached
#
# Returns .config.microvm.declaredRunner (provides /bin/microvm-run).
#
{
  pkgs,
  lib,
  microvm,
  nixpkgs,
  constants, # shared app constants (nginxPort, cacheMaxSize, ...)
  vmConstants, # ./constants.nix
  ociImage, # the streamLayeredImage script
  siegeBenchmark, # siege load-test runner, so it can run inside the guest too
}:

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

          # Host -> guest port forward. `curl host:${nginxPort}` on the
          # hypervisor reaches the guest, where docker -p routes it to nginx.
          forwardPorts = [
            {
              from = "host";
              host.port = constants.nginxPort;
              guest.port = constants.nginxPort;
            }
          ];

          # Real disk for /var/lib/docker (tmpfs root can't hold the image).
          volumes = [
            {
              image = "docker-var.img";
              mountPoint = "/var/lib/docker";
              size = vmConstants.dockerDiskSize;
              fsType = "ext4";
              autoCreate = true;
            }
          ];

          # Share the host store read-only so the image + its closure are
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

        # Bring eth0 up via DHCP (SLiRP hands out 10.0.2.15); without an IP the
        # hostfwd'd packets have nowhere to land.
        systemd.network.enable = true;
        networking.useNetworkd = true;
        networking.useDHCP = false;
        systemd.network.networks."20-lan" = {
          matchConfig.MACAddress = vmConstants.mac;
          networkConfig.DHCP = "yes";
        };

        networking.firewall.allowedTCPPorts = [ constants.nginxPort ];

        virtualisation.docker = {
          enable = true;
          enableOnBoot = true;
        };

        # docker CLI for debugging; siege-benchmark so you can load-test from
        # inside the guest (bypasses host<->guest network overhead):
        #   siege-benchmark --target cached
        environment.systemPackages = [
          pkgs.docker
          siegeBenchmark
        ];

        # Load the OCI image from the store and run it, publishing the nginx
        # port and mounting the cache dir as tmpfs (RAM-backed cache).
        systemd.services.webapp = {
          description = "Load and run the webapp OCI image";
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
            ${ociImage} | docker load

            docker rm -f webapp >/dev/null 2>&1 || true

            exec docker run --rm --name webapp \
              --publish ${toString constants.nginxPort}:${toString constants.nginxPort} \
              --tmpfs /var/cache/nginx:size=${constants.cacheMaxSize} \
              webapp:latest
          '';
        };
      }
    )
  ];
}).config.microvm.declaredRunner
