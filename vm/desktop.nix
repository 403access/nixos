# Default desktop profile for the OrbStack test machine.
#
# `apply.sh` writes the selected profile to /etc/nixos/vm/desktop.nix in the
# machine.  This tracked file documents the default and can be used as a
# starting point for a manual configuration:
#
#   DESKTOP_PROFILE=plasma ./vm/apply.sh
#   ./vm/vm.sh desktop rice
#
# Valid values: xfce, rice, plasma, hyprland.  Hyprland is Wayland-only,
# so it cannot be served over the X11 VNC display used by this VM.
{ ... }:

{
  myDesktop.profile = "rice";
}
