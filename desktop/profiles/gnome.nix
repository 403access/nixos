{ config, lib, pkgs, ... }:

let
  cfg = config.myDesktop;
  useWhiteSur = cfg.gtkTheme == "whitesur";
in
lib.mkIf (cfg.enable && cfg.profile == "gnome") {
  services.xserver.enable = true;
  services.xserver.desktopManager.gnome.enable = true;
  services.xserver.displayManager.gdm.enable = true;

  # The host may still enable XFCE/LightDM directly; GNOME owns the session.
  services.xserver.desktopManager.xfce.enable = lib.mkForce false;
  services.xserver.displayManager.lightdm.enable = lib.mkForce false;

  services.displayManager.defaultSession = "gnome";
  services.xrdp.defaultWindowManager = lib.mkForce "gnome-session";

  environment.systemPackages = with pkgs; [
    gnomeExtensions.user-themes
    gnomeExtensions.dash-to-dock
    gnomeExtensions.blur-my-shell
    gnome-tweaks
  ];

  # WhiteSur's GNOME Shell theme is the part that gives the macOS-style top
  # bar.  The user-theme extension loads it from the system theme directory.
  programs.dconf.profiles.user.databases = lib.mkIf useWhiteSur [
    {
      settings = {
        "org/gnome/shell" = {
          enabled-extensions = [
            "user-theme@gnome-shell-extensions.gcampax.github.com"
            "dash-to-dock@micxgx.gmail.com"
            "blur-my-shell@aunetx"
          ];
        };
        "org/gnome/shell/extensions/user-theme" = {
          name = cfg.gtkThemeName;
        };
        "org/gnome/shell/extensions/dash-to-dock" = {
          dock-position = "BOTTOM";
          extend-height = false;
          transparency-mode = "FIXED";
        };
      };
    }
  ];

  myDesktop.sessionCommand =
    "${pkgs.dbus}/bin/dbus-run-session ${pkgs.gnome-session}/bin/gnome-session";
  myDesktop.sessionType = "x11";
  myDesktop.supportedOverVnc = true;
}
