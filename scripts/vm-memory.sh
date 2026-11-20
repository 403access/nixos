#!/usr/bin/env bash
#
# vm-memory.sh - set the persistent memory allocation of a libvirt guest.
#
# Usage: sudo ./scripts/vm-memory.sh [GiB] [DOMAIN]
#        sudo ./scripts/vm-memory.sh 8 win11-stock
#
# If the guest is running it is shut down gracefully, resized, and started
# again.  A guest that does not shut down within three minutes aborts the
# script; nothing is destroyed.
set -euo pipefail

gib="${1:-8}"
domain="${2:-win11-stock}"

die() { printf 'vm-memory: %s\n' "$*" >&2; exit 1; }

case "$gib" in
  '' | *[!0-9]*) die "memory must be an integer number of GiB, for example 8" ;;
esac
[ "$gib" -ge 4 ] || die "Windows 11 needs at least 4 GiB"
[ "$gib" -le 64 ] || die "refusing more than 64 GiB"

command -v virsh >/dev/null 2>&1 || die "virsh is not installed"
virsh dominfo "$domain" >/dev/null 2>&1 \
  || die "cannot query '$domain'; run as a member of libvirtd or with sudo"

state="$(virsh domstate "$domain" 2>/dev/null || true)"
was_running=0

if [ "$state" = "running" ] || [ "$state" = "paused" ]; then
  was_running=1
  printf 'Shutting down %s ...\n' "$domain"
  virsh shutdown "$domain" >/dev/null 2>&1 || true
  for _ in $(seq 1 90); do
    [ "$(virsh domstate "$domain" 2>/dev/null || true)" = "shut off" ] && break
    sleep 2
  done
  if [ "$(virsh domstate "$domain" 2>/dev/null || true)" != "shut off" ]; then
    die "guest did not shut down within 180s; save your work, shut it down, and rerun"
  fi
elif [ "$state" != "shut off" ]; then
  die "unexpected domain state: $state"
fi

printf 'Setting %s memory to %s GiB ...\n' "$domain" "$gib"
virsh setmaxmem "$domain" "${gib}G" --config
virsh setmem "$domain" "${gib}G" --config

if [ "$was_running" -eq 1 ]; then
  printf 'Starting %s ...\n' "$domain"
  virsh start "$domain" >/dev/null
fi

printf '\n%s now reports:\n' "$domain"
virsh dominfo "$domain" | grep -E 'State|Max memory|Used memory|Autostart' || true
printf '\nRun scripts/vm-stats.sh %s to compare host RSS.\n' "$domain"