#!/usr/bin/env bash
#
# Read-only ZFS/NixOS audit.
#
# This script never writes to a disk, never imports a pool, never scrubs,
# snapshots, mounts, unmounts or destroys anything.  Every command is an
# inspection command.  Run it as root so SMART and blkid return full data:
#
#   sudo ./scripts/zfs-audit.sh | tee ~/zfs-audit.txt
#
# Paste ~/zfs-audit.txt back.  It is safe to share after checking the tail of
# `zpool history` and `testparm` for paths or names you consider private.
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  printf 'run as root: sudo %s\n' "$0" >&2
  exit 1
fi

section() { printf '\n===== %s =====\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
show() { "$@" 2>&1 || true; }

section "System"
date -Is
uname -a
show grep -E '^(NAME|VERSION)=' /etc/os-release
show nixos-version

section "Configuration state"
if git -C /etc/nixos rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'git commit: %s\n' "$(git -C /etc/nixos rev-parse --short HEAD 2>/dev/null)"
  git -C /etc/nixos status --short 2>/dev/null | head -20
else
  printf '/etc/nixos is not a git checkout\n'
fi
show cat /etc/nixos/installation-mode.nix

section "Block devices"
show lsblk -o NAME,TYPE,SIZE,FSTYPE,FSVER,LABEL,UUID,PARTTYPE,PARTLABEL,MODEL,SERIAL,WWN,ROTA,MOUNTPOINT

section "Root / tank overlap"
root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
root_disk=""
if [ -n "$root_src" ]; then
  root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1)"
  [ -n "$root_disk" ] && root_disk="/dev/$root_disk"
  [ -z "$root_disk" ] && root_disk="$root_src"
fi
printf 'root source: %s\n' "${root_src:-unknown}"
printf 'root disk:   %s\n' "${root_disk:-unknown}"

section "tank members (physical paths)"
show zpool status -P tank

section "blkid signatures"
show blkid

section "ZFS pool status"
show zpool status -v

section "ZFS pool list"
show zpool list -v

section "ZFS pool properties"
show zpool get all tank

section "Importable pools (list only, no import)"
show zpool import

section "Datasets"
show zfs list -o name,used,avail,refer,mountpoint,recordsize,compression,quota,reservation,readonly,canmount,encryption,keystatus

section "Mount state"
show zfs get -r -o name,property,value mounted tank
show findmnt -t zfs -o TARGET,SOURCE,FSTYPE,OPTIONS

section "Snapshots"
printf 'count: %s\n' "$(zfs list -H -t snapshot -o name 2>/dev/null | wc -l)"
show zfs list -t snapshot -o name,used,creation -s creation
show zfs get -H -o property,value com.sun:auto-snapshot tank

section "Capacity"
show df -hT
show zpool iostat -v 1 1

section "ARC"
awk '/^size / {print "arc_size_bytes:", $3}' /proc/spl/kstat/zfs/arcstats 2>/dev/null || true
awk '/^c_max / {print "arc_c_max_bytes:", $3}' /proc/spl/kstat/zfs/arcstats 2>/dev/null || true

section "Recent pool events"
timeout 10s zpool events -v 2>/dev/null | tail -40 || true

section "Recent pool history"
zpool history 2>/dev/null | tail -40 || true

section "SMART health of tank members"
if have smartctl; then
  while read -r dev; do
    [ -n "$dev" ] || continue
    real="$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")"
    printf '\n--- %s (%s) ---\n' "$dev" "$real"
    smartctl -H -A -o on -S on "$real" 2>&1 | head -60 || true
  done < <(zpool status -P tank 2>/dev/null | awk '/\/dev\// {print $1}' | sort -u)
else
  printf 'smartctl not installed.  Run this part with:\n'
  printf '  nix-shell -p smartmontools --run "smartctl -H -A /dev/sdX"\n'
fi

section "ZFS services and timers"
show systemctl list-timers --all
show systemctl list-units --type=mount --all

section "Backup tooling"
for tool in sanoid syncoid zfs-auto-snapshot znapzend borg restic rclone; do
  have "$tool" && printf '%s: %s\n' "$tool" "$(command -v "$tool")"
done
show crontab -l
show ls -l /etc/cron.d

section "Exposure (listening sockets)"
show ss -tlnp

section "Samba (effective config)"
if have testparm; then
  testparm -s 2>&1 || true
else
  printf 'testparm not found\n'
fi

section "Virtualisation"
show virsh list --all
show docker ps -a
show zfs list tank/vm

section "Config references to tank / zfs"
show grep -nE 'tank|zfs|fileSystems' /etc/nixos/configuration.nix
show grep -nE 'tank|zfs|fileSystems' /etc/nixos/hardware-configuration.nix

printf '\n===== audit complete =====\n'