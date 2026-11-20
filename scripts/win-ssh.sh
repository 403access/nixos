#!/usr/bin/env bash
# Open a terminal-only SSH session to the Windows VM through the NixOS host.
#
# Usage:
#   ./scripts/win-ssh.sh
#   ./scripts/win-ssh.sh Windows-PC@192.168.122.50
#   WINDOWS_SSH=user@192.168.122.60 ./scripts/win-ssh.sh
#
# The guest IP is the libvirt lease. Find it on the host with:
#   sudo virsh domifaddr win11-stock --source lease
set -euo pipefail

nixos_host="${NIXOS_HOST:-nixos@192.168.178.5}"
target="${WINDOWS_SSH:-Windows-PC@192.168.122.50}"

if [ "$#" -gt 0 ] && [[ "$1" != -* ]]; then
  target="$1"
  shift
fi

exec ssh -J "$nixos_host" "$target" "$@"