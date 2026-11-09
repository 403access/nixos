#!/usr/bin/env bash
# Apply the dedicated Hyprland host configuration.
#
#   ./switch-hyprland.sh dry-build     # build/evaluate only
#   ./switch-hyprland.sh test          # try it for this boot
#   ./switch-hyprland.sh switch        # make it the active system
#   ./switch-hyprland.sh boot          # use it after the next reboot
#
# The config imports the normal configuration.nix, so everything except the
# desktop profile is unchanged.  The Hyprland profile disables xrdp; revert
# to the default XFCE setup with `sudo nixos-rebuild switch`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$ROOT/configuration-hyprland.nix"
ACTION="${1:-switch}"

usage() {
  cat <<'EOF'
Usage: ./switch-hyprland.sh [action]

  dry-build     evaluate and build the Hyprland configuration
  dry-activate  show what activation would do
  test          build and activate for this boot only
  boot          build and use it after the next reboot
  switch        build and activate now (default)

The Hyprland profile is Wayland-only and disables xrdp.
Revert with: sudo nixos-rebuild switch
EOF
}

case "$ACTION" in
  dry-build|dry-activate|test|boot|switch) ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

if [[ ! -f "$CONFIG" ]]; then
  echo "Missing $CONFIG" >&2
  exit 1
fi

if ! command -v nixos-rebuild >/dev/null 2>&1; then
  echo "nixos-rebuild was not found. Run this script on the NixOS host." >&2
  exit 1
fi

echo "Applying Hyprland configuration ($ACTION)..."
echo "The Hyprland profile is Wayland-only and disables xrdp."
echo

sudo nixos-rebuild "$ACTION" -I "nixos-config=$CONFIG"

if [[ "$ACTION" == "switch" || "$ACTION" == "test" ]]; then
  echo
  echo "Done. Log out and choose Hyprland at SDDM if it did not start automatically."
  echo "SDDM is configured to auto-login so the VNC endpoint starts without a"
  echo "physical login; remove services.displayManager.autoLogin in"
  echo "configuration-hyprland.nix if you prefer a manual login."
  echo
  echo "The Hyprland session serves VNC on 127.0.0.1:5900 (loopback only)."
  echo "From another machine, tunnel it and open vnc://127.0.0.1:5900:"
  echo
  echo "  ssh -L 5900:127.0.0.1:5900 <user>@<host>"
  echo
  echo "If the host has no monitor, a headless output is created automatically."
  echo "Revert with: sudo nixos-rebuild switch"
fi
