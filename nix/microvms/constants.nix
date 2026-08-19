# nix/microvms/constants.nix
#
# MicroVM runtime constants. App-level ports (nginxPort) come from the shared
# ../constants.nix and are threaded in by mkVm.nix.
#
{
  hostname = "webapp-vm";

  # RAM (MiB). Avoid exactly 2048 — microvm.nix #171: QEMU hangs at boot when
  # memory is exactly 2 GiB. 3072 leaves headroom for dockerd + BOTH stacks
  # (Python uWSGI/Django and Rust monoio) running side by side.
  mem = 3072;

  vcpu = 2;

  useKvm = true;

  # ext4 disk (MiB) for /var/lib/docker — must hold BOTH OCI images plus
  # dockerd's working storage.
  dockerDiskSize = 10240;

  # QEMU-visible NIC MAC (also used to match the interface for DHCP in-guest).
  mac = "02:00:00:00:00:01";
}
