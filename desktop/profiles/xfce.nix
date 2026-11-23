{ config, lib, pkgs, ... }:

let
  cfg = config.myDesktop;

  # xfdesktop stores the backdrop per monitor in the user's xfconf database,
  # which survives rebuilds and can point at an old or missing image.  Apply
  # the declarative wallpaper at session start so a theme change (or a fresh
  # xrdp session) always shows the selected wallpaper.
  applyWallpaper = pkgs.writeShellApplication {
    name = "desktop-xfce-wallpaper";
    runtimeInputs = [ pkgs.xfce.xfconf pkgs.coreutils pkgs.gnugrep ];
    text = ''
      if [ -z "''${DISPLAY:-}" ]; then
        exit 0
      fi

      wallpaper=${lib.escapeShellArg "${cfg.wallpaper}"}

      # xfdesktop creates the backdrop properties shortly after it starts.
      props=""
      for _ in $(seq 1 20); do
        props=$(xfconf-query -c xfce4-desktop -l 2>/dev/null \
          | grep -E '^/backdrop/.*/(image-path|last-image)$' || true)
        if [ -n "$props" ]; then
          break
        fi
        sleep 0.5
      done

      if [ -z "$props" ]; then
        xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor0/image-path \
          -n -t string -s "$wallpaper"
        xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor0/image-show \
          -n -t bool -s true
        xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor0/image-style \
          -n -t int -s 5
        exit 0
      fi

      printf '%s\n' "$props" | while IFS= read -r prop; do
        [ -n "$prop" ] || continue
        xfconf-query -c xfce4-desktop -p "$prop" -s "$wallpaper" || true
      done

      xfconf-query -c xfce4-desktop -l 2>/dev/null \
        | grep -E '^/backdrop/.*/(image-show|image-style)$' \
        | while IFS= read -r prop; do
            case "$prop" in
              */image-show)
                xfconf-query -c xfce4-desktop -p "$prop" -s true || true
                ;;
              */image-style)
                xfconf-query -c xfce4-desktop -p "$prop" -s 5 || true
                ;;
            esac
          done
    '';
  };

  # Apply the wallpaper to sessions that are already running (for example
  # after a theme rebuild), not just at the next login.
  applyWallpaperSessions = pkgs.writeShellApplication {
    name = "desktop-xfce-wallpaper-sessions";
    runtimeInputs = [ pkgs.coreutils pkgs.procps pkgs.util-linux pkgs.gnugrep ];
    text = ''
      hook=${lib.escapeShellArg "${applyWallpaper}/bin/desktop-xfce-wallpaper"}

      for pid in $(pgrep -x xfce4-session); do
        [ -r "/proc/$pid/environ" ] || continue
        user=$(stat -c %U "/proc/$pid")
        [ "$user" != root ] || continue
        envs=$(tr '\0' '\n' < "/proc/$pid/environ")
        display=$(printf '%s\n' "$envs" | sed -n 's/^DISPLAY=//p')
        xauth=$(printf '%s\n' "$envs" | sed -n 's/^XAUTHORITY=//p')
        dbus=$(printf '%s\n' "$envs" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
        [ -n "$display" ] || continue

        set -- env "DISPLAY=$display"
        if [ -n "$xauth" ]; then
          set -- "$@" "XAUTHORITY=$xauth"
        fi
        if [ -n "$dbus" ]; then
          set -- "$@" "DBUS_SESSION_BUS_ADDRESS=$dbus"
        fi
        runuser -u "$user" -- "$@" "$hook" || true
      done
    '';
  };
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
    applyWallpaper
  ];

  environment.etc."xdg/autostart/nixos-wallpaper.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Desktop wallpaper
    Comment=Apply the wallpaper selected in NixOS Control
    Exec=${applyWallpaper}/bin/desktop-xfce-wallpaper
    OnlyShowIn=XFCE;
    NoDisplay=true
    X-GNOME-Autostart-enabled=true
  '';

  # Restarting this unit on a rebuild reapplies the wallpaper to any live
  # XFCE session.  The unit changes whenever the selected wallpaper does.
  systemd.services.nixos-xfce-wallpaper = {
    description = "Apply the selected wallpaper to running XFCE sessions";
    wantedBy = [ "multi-user.target" ];
    after = [ "display-manager.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${applyWallpaperSessions}/bin/desktop-xfce-wallpaper-sessions";
    };
  };

  environment.sessionVariables = {
    QT_QPA_PLATFORMTHEME = "qt6ct";
    QT_STYLE_OVERRIDE = "kvantum";
  };

  myDesktop.sessionCommand =
    "${pkgs.dbus}/bin/dbus-run-session ${pkgs.xfce.xfce4-session}/bin/xfce4-session";
  myDesktop.sessionType = "x11";
  myDesktop.supportedOverVnc = true;
}
