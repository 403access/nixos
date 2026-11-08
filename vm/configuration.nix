# Disposable local testbed for the NixOS Control module.
#
# This module is deliberately NOT imported by the real host configuration in
# ../configuration.nix. It is meant to be layered on top of a throwaway NixOS
# machine (see ./README.md for the OrbStack recipe) and therefore:
#
#   * binds the API to all interfaces so macOS and the iOS Simulator can reach
#     it at http://<machine>.orb.local:8787,
#   * skips Tailscale Serve, which needs a real tailnet,
#   * starts a small XFCE desktop on a VNC display for visual access.
{ lib, pkgs, ... }:

let
  vncPassword = "nixos";
  vncUser = "vnc";
  vncPort = 5901;
  xfce = pkgs.xfce;
in
{
  imports = [ ../nixos-control.nix ];

  services.nixos-control = {
    enable = true;

    # Reachable from the Mac, the iOS Simulator, and anything else on the
    # OrbStack network.
    address = "0.0.0.0";
    openFirewall = true;

    # No tailnet in the test machine.
    tailscaleServe.enable = false;
  };

  # --- Desktop over VNC ---------------------------------------------------
  # Only the API port is opened by the module's openFirewall above.
  networking.firewall.allowedTCPPorts = [ vncPort ];

  users.users.${vncUser} = {
    isNormalUser = true;
    createHome = true;
    home = "/home/${vncUser}";
  };

  environment.systemPackages = with pkgs; [
    tigervnc
    xfce.xfce4-session
    xfce.xfwm4
    xfce.xfce4-panel
    xfce.xfdesktop
    xfce.xfce4-settings
    xfce.xfconf
    xfce.exo
    xfce.garcon
    xfce.thunar
    xfce.xfce4-appfinder
    xfce.xfce4-terminal
    xfce.tumbler
    xfce.xfce4-notifyd
    xfce.xfce4-power-manager
    xfce.xfce4-screenshooter
    xfce.xfce4-taskmanager
    xfce.mousepad
    xfce.ristretto
    scrot
    curl
    jq
    dbus
  ];

  fonts.packages = with pkgs; [
    dejavu_fonts
    liberation_ttf
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
    description = "XFCE session on the VNC display";
    wantedBy = [ "multi-user.target" ];
    requires = [ "vnc-server.service" ];
    after = [ "vnc-server.service" ];
    environment = {
      DISPLAY = ":1";
      HOME = "/home/${vncUser}";
      # dbus-run-session looks up dbus-daemon and XFCE starts its helpers by
      # name; system units otherwise get a PATH that excludes the system
      # profile.
      PATH = lib.mkForce "/run/current-system/sw/bin:/run/current-system/sw/sbin";
      # Login sessions get these from /etc/set-environment; a plain system
      # unit does not, and xfce4-session cannot find its failsafe session
      # without the profile's xdg directories.
      XDG_CONFIG_DIRS = "/etc/xdg:/run/current-system/sw/etc/xdg";
      XDG_DATA_DIRS = "/run/current-system/sw/share";
      XDG_RUNTIME_DIR = "/run/vnc";
      XDG_SESSION_TYPE = "x11";
      XDG_SESSION_DESKTOP = "xfce";
      XDG_CURRENT_DESKTOP = "XFCE";
    };
    serviceConfig = {
      Type = "simple";
      User = vncUser;
      WorkingDirectory = "/home/${vncUser}";
      RuntimeDirectory = "vnc";
      RuntimeDirectoryMode = "0700";
      ExecStart = "${pkgs.dbus}/bin/dbus-run-session ${xfce.xfce4-session}/bin/xfce4-session";
      Restart = "on-failure";
      RestartSec = 3;
    };
  };
}
