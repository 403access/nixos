# InputLeap client: forwards the Mac's keyboard and mouse to the physical
# X display of this machine, at the lightdm greeter and inside the X11
# desktop session.  The Mac runs InputLeap as the server (screen layout:
# Mac on the right, `nixos` on the left).
#
# The client must run as root: the greeter's X cookie lives in
# /var/run/lightdm/root/:0, which only root can read.
{ config, pkgs, lib, ... }:

let
  # Mac's LAN address (the InputLeap server).
  serverHost = "192.168.178.33";
  # Must match the screen name in the Mac's InputLeap layout.
  screenName = "nixos";
  # SHA-256 of the Mac's InputLeap self-signed certificate.  The client
  # pins this so it never trusts a different server on the LAN.
  serverFingerprint = "v2:sha256:d3a3448b8f3f19970118cb5592f2cd4d0588349277c326f1f892988a2fb3bfb7";
  # Desktop user whose ~/.Xauthority is used after login.
  desktopUser = "nixos";

  # Runs before every (re)start: pin the server certificate and build a
  # cookie file that can reach :0 both at the greeter and in the session.
  prepare = pkgs.writeShellScript "input-leap-client-prepare" ''
    set -u
    umask 077
    install -d -m 700 /run/input-leap
    install -d -m 700 /root/.config/InputLeap/SSL/Fingerprints
    printf '%s\n' "${serverFingerprint}" \
      > /root/.config/InputLeap/SSL/Fingerprints/TrustedServers.txt
    chmod 600 /root/.config/InputLeap/SSL/Fingerprints/TrustedServers.txt

    # Drop a leftover manual client; the unit owns the process now.
    ${pkgs.procps}/bin/pkill -x input-leapc >/dev/null 2>&1 || true

    for _ in $(seq 1 60); do
      for src in /var/run/lightdm/root/:0 /home/${desktopUser}/.Xauthority; do
        [ -r "$src" ] || continue
        rm -f /run/input-leap/xauthority
        ${pkgs.xorg.xauth}/bin/xauth -f /run/input-leap/xauthority merge "$src" \
          >/dev/null 2>&1 || continue
        [ -s /run/input-leap/xauthority ] || continue
        if DISPLAY=:0 XAUTHORITY=/run/input-leap/xauthority \
             ${pkgs.xorg.xdpyinfo}/bin/xdpyinfo >/dev/null 2>&1; then
          exit 0
        fi
      done
      sleep 1
    done

    # No reachable display yet.  Start anyway; the client exits and the
    # unit retries in a couple of seconds.
    exit 0
  '';
in
{
  environment.systemPackages = [ pkgs.input-leap ];

  systemd.services.input-leap-client = {
    description = "InputLeap client (Mac keyboard and mouse on the physical display)";
    wantedBy = [ "multi-user.target" ];
    wants = [ "display-manager.service" ];
    after = [ "display-manager.service" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "2s";
      ExecStartPre = prepare;
      ExecStart = "${pkgs.input-leap}/bin/input-leapc --no-daemon --name ${screenName} --use-x11 --display :0 --debug INFO ${serverHost}:24800";
      Environment = [
        "DISPLAY=:0"
        "XAUTHORITY=/run/input-leap/xauthority"
      ];
    };
  };
}