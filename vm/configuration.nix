# Disposable local testbed for the NixOS Control module and the desktop
# profiles.
#
# This module is deliberately NOT imported by the real host configuration in
# ../configuration.nix. It is meant to be layered on top of a throwaway NixOS
# machine (see ./README.md for the OrbStack recipe) and therefore:
#
#   * binds the API to all interfaces so macOS and the iOS Simulator can reach
#     it at http://<machine>.orb.local:8787,
#   * skips Tailscale Serve, which needs a real tailnet,
#   * starts the selected X11 desktop on a VNC display for visual access.
#
# The profile itself is written to ./desktop.nix by ../apply.sh.  XFCE, the
# Catppuccin i3 rice, and KDE Plasma all work over the X11 VNC display;
# Hyprland needs Wayland and real graphics hardware.
{ config, lib, pkgs, ... }:

let
  vncPassword = "nixos";
  vncUser = "vnc";
  vncPort = 5901;
  profile = config.myDesktop.profile;
in
{
  imports = [
    ../nixos-control.nix
    ../desktop
  ];

  assertions = [
    {
      assertion = config.myDesktop.supportedOverVnc;
      message = ''
        The OrbStack test machine serves an X11 desktop over VNC.
        myDesktop.profile = "${profile}" needs Wayland; use "xfce",
        "rice", or "plasma" for the VM and test Hyprland on real hardware.
      '';
    }
  ];

  services.nixos-control = {
    enable = true;

    # Reachable from the Mac, the iOS Simulator, and anything else on the
    # OrbStack network.
    address = "0.0.0.0";
    openFirewall = true;

    # No tailnet in the test machine.
    tailscaleServe.enable = false;
  };

  myDesktop = {
    enable = true;
    user = vncUser;
    home = "/home/${vncUser}";

    # The VNC session is started by systemd below, not by a greeter.
    enableDisplayManager = false;
  };

  # --- Desktop over VNC ---------------------------------------------------
  # Only the API port is opened by the module's openFirewall above.
  networking.firewall.allowedTCPPorts = [ vncPort ];

  users.users.${vncUser} = {
    isNormalUser = true;
    createHome = true;
    home = "/home/${vncUser}";
    # Also used by Plasma's lock screen and i3lock.  The VNC connection
    # password is the same value.
    password = vncPassword;
  };

  environment.systemPackages = with pkgs; [
    tigervnc
    scrot
    curl
    jq
    dbus
  ];

  systemd.services.vnc-server = {
    description = "TigerVNC server for the NixOS Control test desktop";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-user-sessions.service" ];
    serviceConfig = {
      Type = "simple";
      User = vncUser;
      WorkingDirectory = "/home/${vncUser}";
      ExecStartPre = pkgs.writeShellScript "vnc-password" ''
        umask 077
        printf '%s\n' ${lib.escapeShellArg vncPassword} | ${pkgs.tigervnc}/bin/vncpasswd -f > /home/${vncUser}/.vncpasswd
      '';
      ExecStart = ''
        ${pkgs.tigervnc}/bin/Xvnc :1 \
          -geometry 1600x1000 -depth 24 \
          -rfbport ${toString vncPort} -localhost no \
          -SecurityTypes VncAuth -PasswordFile /home/${vncUser}/.vncpasswd \
          -AlwaysShared -AcceptKeyEvents -AcceptPointerEvents \
          -AcceptCutText -SendCutText
      '';
      Restart = "on-failure";
      RestartSec = 2;
    };
  };

  systemd.services.vnc-session = {
    description = "Desktop session on the VNC display (${profile})";
    wantedBy = [ "multi-user.target" ];
    requires = [ "vnc-server.service" ];
    after = [ "vnc-server.service" ];
    environment = config.environment.sessionVariables // {
      DISPLAY = ":1";
      HOME = "/home/${vncUser}";
      # dbus-run-session looks up dbus-daemon and the desktop starts its
      # helpers by name; system units otherwise get a PATH that excludes the
      # system profile.
      PATH = lib.mkForce "/run/current-system/sw/bin:/run/current-system/sw/sbin";
      # Login sessions get these from /etc/set-environment; a plain system
      # unit does not, and desktop sessions cannot find their xdg dirs
      # without them.
      XDG_CONFIG_DIRS = "/etc/xdg:/run/current-system/sw/etc/xdg";
      XDG_DATA_DIRS = "/run/current-system/sw/share";
      # Plasma needs the system QML/plugin paths that a normal login gets
      # from /etc/set-environment; this systemd unit starts the session
      # directly, so provide them explicitly.
      QML2_IMPORT_PATH = "/run/current-system/sw/lib/qt-5.15.18/qml:/run/current-system/sw/lib/qt-6/qml";
      QT_PLUGIN_PATH = "/run/current-system/sw/lib/qt-5.15.18/plugins:/run/current-system/sw/lib/qt-6/plugins";
      XDG_RUNTIME_DIR = "/run/vnc";
      XDG_SESSION_TYPE = config.myDesktop.sessionType;
      XDG_SESSION_DESKTOP = profile;
      XDG_CURRENT_DESKTOP =
        if profile == "plasma" then "KDE"
        else if profile == "xfce" then "XFCE"
        else profile;
      DESKTOP_SESSION = profile;
      LIBGL_ALWAYS_SOFTWARE = "1";
    } // lib.optionalAttrs (profile == "plasma") {
      KDE_FULL_SESSION = "true";
      KDE_SESSION_VERSION = "6";
    };
    serviceConfig = {
      Type = "simple";
      User = vncUser;
      WorkingDirectory = "/home/${vncUser}";
      RuntimeDirectory = "vnc";
      RuntimeDirectoryMode = "0700";
      ExecStart = config.myDesktop.sessionCommand;
      Restart = "always";
      RestartSec = 3;
    };
  };
}
