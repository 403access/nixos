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

  # Serve the Hyprland session over VNC on loopback.  Use it through an SSH
  # tunnel (or Tailscale) from another machine:
  #
  #   ssh -L 5900:127.0.0.1:5900 nixos@<host>
  #   open vnc://127.0.0.1:5900
  #
  # If the host has no monitor, a headless output is created automatically.
  hyprVnc = pkgs.writeShellScriptBin "desktop-hypr-vnc" ''
    set -euo pipefail

    for _ in $(seq 1 50); do
      hyprctl monitors >/dev/null 2>&1 && break
      sleep 0.2
    done

    output=$(${pkgs.jq}/bin/jq -r '.[0].name // empty' \
      < <(hyprctl monitors -j 2>/dev/null) 2>/dev/null || true)

    if [ -z "$output" ]; then
      hyprctl output create headless HEADLESS-VNC >/dev/null 2>&1 || true
      sleep 1
      output=$(${pkgs.jq}/bin/jq -r '.[0].name // empty' \
        < <(hyprctl monitors -j 2>/dev/null) 2>/dev/null || true)
    fi

    if [ -n "$output" ]; then
      exec ${pkgs.wayvnc}/bin/wayvnc -o "$output" 127.0.0.1 5900
    else
      exec ${pkgs.wayvnc}/bin/wayvnc 127.0.0.1 5900
    fi
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

  # Hyprland needs the DRM device; render nodes are also used by EGL.
  users.users.${cfg.user}.extraGroups = [ "video" "render" ];

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
    wayvnc
    jq
    powermenu
    hyprVnc
  ];

  environment.sessionVariables = {
    # The host may be headless or not on the active VT.  This lets Hyprland
    # start and create a HEADLESS output for wayvnc instead of waiting for KMS.
    AQ_NO_KMS_REQUIREMENT = "1";
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
