{ config, lib, pkgs, ... }:
{
  networking.firewall.allowedTCPPorts = [ 3050 ];

  systemd.services.nixos-control-web = {
    description = "NixOS Control web dashboard";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "nixos-control.service" ];
    wants = [ "nixos-control.service" ];

    serviceConfig = {
      User = "nixos";
      Group = "users";
      WorkingDirectory = "/home/nixos/peripherals-ui";
      Environment = [
        "API_TARGET=http://127.0.0.1:8787"
        "PORT=3050"
      ];
      ExecStart = "${pkgs.bun}/bin/bun server.ts";
      Restart = "on-failure";
      RestartSec = 2;
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
  };
}