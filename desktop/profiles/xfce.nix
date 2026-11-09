{ config, lib, pkgs, ... }:

let
  cfg = config.myDesktop;
in
lib.mkIf (cfg.enable && cfg.profile == "xfce") {
  services.xserver.enable = true;
  services.xserver.desktopManager.xfce.enable = true;
  services.tumbler.enable = true;

  services.displayManager.defaultSession = "xfce";
  services.xrdp.defaultWindowManager = "startxfce4";

  environment.systemPackages = with pkgs; [
    xfce.xfce4-whiskermenu-plugin
    xfce.xfce4-power-manager
    xfce.xfce4-terminal
    xfce.xfce4-screenshooter
    xfce.xfce4-taskmanager
    xfce.xfce4-notifyd
    xfce.mousepad
    xfce.ristretto
    xfce.garcon
  ];

  environment.sessionVariables = {
    QT_QPA_PLATFORMTHEME = "qt6ct";
    QT_STYLE_OVERRIDE = "kvantum";
  };

  myDesktop.sessionCommand =
    "${pkgs.dbus}/bin/dbus-run-session ${pkgs.xfce.xfce4-session}/bin/xfce4-session";
  myDesktop.sessionType = "x11";
  myDesktop.supportedOverVnc = true;
}
