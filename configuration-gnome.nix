{ config, lib, pkgs, ... }:

{
  imports = [ ./configuration.nix ./desktop ];

  myDesktop = {
    enable = lib.mkForce true;
    profile = lib.mkForce "gnome";
    user = lib.mkForce "nixos";

    gtkTheme = lib.mkForce "whitesur";
    whiteSur = {
      variant = lib.mkForce "dark";
      accent = lib.mkForce "blue";
      icons = lib.mkForce true;
      cursors = lib.mkForce true;
      plank = lib.mkForce false;
    };
  };

  # GNOME owns the session when this wrapper is selected.
  services.xserver.desktopManager.xfce.enable = lib.mkForce false;
  services.xserver.displayManager.lightdm.enable = lib.mkForce false;
  services.xserver.displayManager.gdm.enable = lib.mkForce true;
  services.displayManager.defaultSession = lib.mkForce "gnome";
}
