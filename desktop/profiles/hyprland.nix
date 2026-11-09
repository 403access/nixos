{ config, lib, pkgs, ... }:

let
  cfg = config.myDesktop;

  dotfiles = import ../dotfiles.nix { inherit pkgs lib; } "hyprland" ../hyprland {
    "hypr/hyprpaper.conf" = {
      from = "@WALLPAPER@";
      to = cfg.wallpaper;
    };
  };

  # Reuse the Kitty and Rofi themes from the X11 rice.
  sharedDotfiles = import ../dotfiles.nix { inherit pkgs lib; } "hyprland-shared" ../rice {
    "i3/config" = {
      from = "@WALLPAPER@";
      to = cfg.wallpaper;
    };
  };

  powermenu = pkgs.writeShellScriptBin "desktop-powermenu" ''
    set -euo pipefail
    choice=$(printf '%s\n' \
      "Lock" \
      "Logout" \
      "Suspend" \
      "Reboot" \
      "Shutdown" \
      | ${pkgs.rofi}/bin/rofi -dmenu -i -p "Power" -theme-str 'window { width: 300px; }')

    case "$choice" in
      Lock)     ${pkgs.hyprlock}/bin/hyprlock ;;
      Logout)   ${pkgs.hyprland}/bin/hyprctl dispatch exit ;;
      Suspend)  systemctl suspend ;;
      Reboot)   systemctl reboot ;;
      Shutdown) systemctl poweroff ;;
      *)        exit 0 ;;
    esac
  '';

in
lib.mkIf (cfg.enable && cfg.profile == "hyprland") {
  services.xserver.enable = true;
  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };

  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [
      xdg-desktop-portal-hyprland
      xdg-desktop-portal-gtk
    ];
    config.common.default = [ "hyprland" "gtk" ];
  };

  services.displayManager.defaultSession = "hyprland";

  # xrdp speaks X11; a Hyprland session cannot be exported over it.  The
  # XFCE or rice profile remains available if remote X11 access is needed.
  services.xrdp.enable = lib.mkForce false;
  warnings = [
    "myDesktop.profile = \"hyprland\" is Wayland-only; xrdp has been disabled. Use the xfce or rice profile if you need xrdp."
  ];

  environment.systemPackages = with pkgs; [
    waybar
    mako
    hyprpaper
    hyprlock
    hypridle
    hyprpicker
    rofi
    grim
    slurp
    wl-clipboard
    cliphist
    swappy
    blueman
    libnotify
    playerctl
    brightnessctl
    pamixer
    powermenu
  ];

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    QT_QPA_PLATFORM = "wayland;xcb";
    QT_QPA_PLATFORMTHEME = "qt6ct";
    QT_STYLE_OVERRIDE = "kvantum";
    GDK_BACKEND = "wayland,x11";
    ELECTRON_OZONE_PLATFORM_HINT = "auto";
    XDG_SESSION_TYPE = "wayland";
    XDG_CURRENT_DESKTOP = "Hyprland";
    XDG_SESSION_DESKTOP = "Hyprland";
  };

  systemd.tmpfiles.rules = [
    "d ${cfg.home}/.config 0755 ${cfg.user} users -"
    "L+ ${cfg.home}/.config/hypr - - - - ${dotfiles}/hypr"
    "L+ ${cfg.home}/.config/waybar - - - - ${dotfiles}/waybar"
    "L+ ${cfg.home}/.config/mako - - - - ${dotfiles}/mako"
    "L+ ${cfg.home}/.config/kitty - - - - ${sharedDotfiles}/kitty"
    "L+ ${cfg.home}/.config/rofi - - - - ${sharedDotfiles}/rofi"
  ];

  myDesktop.sessionCommand =
    "${pkgs.dbus}/bin/dbus-run-session ${config.programs.hyprland.package}/bin/Hyprland";
  myDesktop.sessionType = "wayland";
  myDesktop.supportedOverVnc = false;
}
