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
{ config, lib, ... }:

{
  imports = [ ./configuration.nix ];

  myDesktop.profile = lib.mkForce "hyprland";

  # wayvnc runs inside the Hyprland session.  Auto-login makes the VNC
  # endpoint available without a physical login at SDDM; remove this block if
  # you prefer to log in manually.
  services.displayManager.autoLogin = {
    enable = true;
    user = config.myDesktop.user;
  };
}
