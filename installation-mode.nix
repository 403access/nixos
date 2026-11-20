# Selected by install/install.sh.
#
# The repository default is a plain NixOS install.  The installer overwrites
# this file on the target system with one of:
#
#   myInstall.mode = "nixos";  # NixOS only
#   myInstall.mode = "vm";     # NixOS + a Windows 11 VM
#   myInstall.mode = "dual";   # NixOS + Windows dual boot
#
# Keeping it in its own file means `nixos-rebuild switch` keeps working after
# the installer has run, and the choice is visible in the configuration.
{ ... }:

{
  # Windows 11 runs in libvirt/QEMU on this machine.
  myInstall.mode = "vm";

  myInstall.vm = {
    user = "nixos";

    # 8 cores / 31 GiB host: leave two cores and ~19 GiB for NixOS, ZFS ARC
    # and the desktop.  Raise to 16384 MiB only if the host is not busy.
    memory = 12288;
    vcpus = 6;

    # The VM disk is a file, not a partition.  Keep it on the NVMe root
    # (1.5 TB free): tank is a mirror of two 8 TB HDDs at 81% capacity, so
    # a guest disk there would be slow and eat the remaining space.
    # Create the VM with --raw to avoid qcow2 copy-on-write overhead.
    diskDir = "/var/lib/libvirt/images";

    # Hugepages pin the guest memory and add a few percent.  They reserve
    # memory for the whole uptime, so they are opt-in: set to true, rebuild,
    # reboot, then create the VM with --hugepages.
    hugepages = false;
  };
}