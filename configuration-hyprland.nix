# Dedicated host configuration that enables the Hyprland desktop profile.
#
# Apply it with:
#
#   ./switch-hyprland.sh dry-build   # evaluate/build without switching
#   ./switch-hyprland.sh switch      # make Hyprland the active session
#
# Revert to the default XFCE configuration later with:
#
#   sudo nixos-rebuild switch
#
# The wrapper intentionally imports the normal configuration.nix, so the
# machine, users, services, ZFS, Tailscale and the API server stay identical.
{ lib, ... }:

{
  imports = [ ./configuration.nix ];

  myDesktop.profile = lib.mkForce "hyprland";
}
