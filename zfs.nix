# Data protection for the tank mirror.
#
# tank is a 2-way mirror of two 8 TB HDDs (sda1 + sdb1) holding 5.92 TB.  A
# mirror survives one disk failure, not deletion, corruption or ransomware.
# Snapshots are the local undo button; offsite copies are still required.
{ pkgs, ... }:

{
  # Hourly run, but only daily/weekly/monthly snapshots are kept.  Sanoid
  # names them autosnap_<timestamp> and prunes them itself.
  services.sanoid = {
    enable = true;
    interval = "hourly";

    templates.production = {
      daily = 30;
      weekly = 8;
      monthly = 12;
      autosnap = true;
      autoprune = true;
    };

    datasets."tank" = {
      use_template = [ "production" ];
      recursive = true;
    };
  };

  # 31 GiB RAM with a 12 GiB Windows guest: cap ARC at 14 GiB so the guest
  # and the desktop are not competing with the cache.  ZFS still uses free
  # memory opportunistically.
  boot.kernelParams = [ "zfs.zfs_arc_max=15032385536" ];

  # smartctl/nvme were missing from the audit.
  environment.systemPackages = with pkgs; [
    smartmontools
    nvme-cli
  ];
}