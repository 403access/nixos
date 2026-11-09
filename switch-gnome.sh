#!/usr/bin/env bash
# Apply the dedicated GNOME + WhiteSur configuration.
#
#   ./switch-gnome.sh dry-build     # build/evaluate only
#   ./switch-gnome.sh test          # try it for this boot
#   ./switch-gnome.sh switch        # make GNOME the active desktop
#   ./switch-gnome.sh boot          # use it after the next reboot
#
# The wrapper imports the normal configuration.nix and forces
# myDesktop.profile = "gnome".  GDM replaces LightDM and the WhiteSur GNOME
# Shell theme is enabled through the user-theme extension.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$ROOT/configuration-gnome.nix"
ACTION="${1:-switch}"

usage() {
  cat <<'EOF'
Usage: ./switch-gnome.sh [action]

  dry-build     evaluate and build the GNOME configuration
  dry-activate  show what activation would do
  test          build and activate for this boot only
  boot          build and use it after the next reboot
  switch        build and activate now (default)

GNOME replaces XFCE/LightDM with GNOME/GDM and enables the WhiteSur
GNOME Shell theme, dash-to-dock and blur-my-shell.
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

echo "Applying GNOME + WhiteSur configuration ($ACTION)..."
echo

sudo nixos-rebuild "$ACTION" -I "nixos-config=$CONFIG"

if [[ "$ACTION" == "switch" || "$ACTION" == "test" ]]; then
  echo
  echo "Done. Reboot or log out and choose GNOME at GDM if it did not start automatically."
  echo "Revert with: sudo nixos-rebuild switch"
fi
