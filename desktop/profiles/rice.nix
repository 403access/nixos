{ config, lib, pkgs, ... }:

let
  cfg = config.myDesktop;

  dotfiles = import ../dotfiles.nix { inherit pkgs lib; } "rice" ../rice {
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
      Lock)     ${pkgs.i3lock}/bin/i3lock -c 11111b ;;
      Logout)   ${pkgs.i3}/bin/i3-msg exit ;;
      Suspend)  systemctl suspend ;;
      Reboot)   systemctl reboot ;;
      Shutdown) systemctl poweroff ;;
      *)        exit 0 ;;
    esac
  '';

  # GLX (blur + rounded corners) on real hardware; XRender on the GPU-less
  # OrbStack VM.
  compositor = pkgs.writeShellScriptBin "desktop-compositor" ''
    if [ -d /dev/dri ]; then
      exec ${pkgs.picom}/bin/picom --config "$HOME/.config/picom/picom-glx.conf"
    else
      exec ${pkgs.picom}/bin/picom --config "$HOME/.config/picom/picom.conf"
    fi
  '';

in
lib.mkIf (cfg.enable && cfg.profile == "rice") {
  services.xserver.enable = true;
  services.xserver.windowManager.i3.enable = true;
  services.xserver.windowManager.i3.extraPackages = [ ];

  services.displayManager.defaultSession = "none+i3";
  services.xrdp.defaultWindowManager = "i3";

  environment.systemPackages = with pkgs; [
    (polybar.override {
      i3Support = true;
      pulseSupport = true;
    })
    picom
    dunst
    feh
    xterm
    flameshot
    scrot
    numlockx
    xdotool
    xorg.xrandr
    arandr
    libnotify
    powermenu
    compositor
  ];

  environment.sessionVariables = {
    QT_QPA_PLATFORMTHEME = "qt6ct";
    QT_STYLE_OVERRIDE = "kvantum";
    BROWSER = "firefox";
    TERMINAL = "xterm";
  };

  # Declarative dotfiles: edit desktop/rice/... and rebuild.
  systemd.tmpfiles.rules = [
    "d ${cfg.home}/.config 0755 ${cfg.user} users -"
    "L+ ${cfg.home}/.config/i3 - - - - ${dotfiles}/i3"
    "L+ ${cfg.home}/.config/polybar - - - - ${dotfiles}/polybar"
    "L+ ${cfg.home}/.config/rofi - - - - ${dotfiles}/rofi"
    "L+ ${cfg.home}/.config/picom - - - - ${dotfiles}/picom"
    "L+ ${cfg.home}/.config/dunst - - - - ${dotfiles}/dunst"
    "L+ ${cfg.home}/.config/kitty - - - - ${dotfiles}/kitty"
    "L+ ${cfg.home}/.Xresources - - - - ${dotfiles}/Xresources"
  ];

  myDesktop.sessionCommand =
    "${pkgs.dbus}/bin/dbus-run-session ${pkgs.i3}/bin/i3";
  myDesktop.sessionType = "x11";
  myDesktop.supportedOverVnc = true;
}
