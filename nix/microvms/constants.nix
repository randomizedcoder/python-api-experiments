# nix/microvms/constants.nix
#
# MicroVM runtime constants. App-level ports (nginxPort) come from the shared
# ../constants.nix and are threaded in by mkVm.nix.
#
{
  hostname = "webapp-vm";

  # RAM (MiB). Avoid exactly 2048 — microvm.nix #171: QEMU hangs at boot when
  # memory is exactly 2 GiB. 2304 (2.25 GiB) sidesteps that and leaves headroom
  # for dockerd + the OpenResty/uWSGI/Django container.
  mem = 2304;

  vcpu = 2;

  useKvm = true;

  # ext4 disk (MiB) for /var/lib/docker — dockerd needs real writable storage;
  # a tmpfs root would fill up loading the image.
  dockerDiskSize = 8192;

  # QEMU-visible NIC MAC (also used to match the interface for DHCP in-guest).
  mac = "02:00:00:00:00:01";
}
