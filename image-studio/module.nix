{ config, lib, pkgs, ... }:

let
  cfg = config.services.image-studio;
  package = pkgs.callPackage ./default.nix { };
in
{
  options.services.image-studio = {
    enable = lib.mkEnableOption "the Image Studio web builder";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8788;
      description = "Port for the web UI and API.";
    };

    bind = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address to bind. Keep loopback and use Tailscale Serve for remote access.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "SSH target used for libvirt/qemu-nbd/NixOS operations. Empty means local.";
    };

    winHost = lib.mkOption {
      type = lib.types.str;
      default = "Windows-PC@192.168.122.50";
      description = "SSH target for the Windows guest.";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = "win11-stock";
      description = "Default libvirt domain.";
    };

    disk = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/libvirt/images/win11-stock.raw";
      description = "Raw Windows disk used by offline image operations.";
    };

    nixosRepo = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos";
      description = "Repository path used for NixOS/Windows build scripts.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/image-studio";
      description = "Jobs, uploads, bundles and imported artifacts.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Optional bearer-token file. Required when bind is not loopback.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the web port in the NixOS firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.image-studio = {
      description = "Image Studio web builder";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "libvirtd.service" ];
      wants = [ "libvirtd.service" ];

      environment = {
        IMAGE_STUDIO_PORT = toString cfg.port;
        IMAGE_STUDIO_BIND = cfg.bind;
        IMAGE_STUDIO_HOST = cfg.host;
        IMAGE_STUDIO_WIN_HOST = cfg.winHost;
        IMAGE_STUDIO_DOMAIN = cfg.domain;
        IMAGE_STUDIO_DISK = cfg.disk;
        IMAGE_STUDIO_NIXOS_REPO = cfg.nixosRepo;
        IMAGE_STUDIO_REPO_ROOT = cfg.nixosRepo;
        IMAGE_STUDIO_DATA = cfg.dataDir;
        IMAGE_STUDIO_DOCKER = "1";
      } // lib.optionalAttrs (cfg.tokenFile != null) {
        IMAGE_STUDIO_TOKEN_FILE = toString cfg.tokenFile;
      };

      serviceConfig = {
        ExecStart = "${package}/bin/image-studio web";
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${cfg.dataDir}";
        Restart = "on-failure";
        RestartSec = 5;
        StateDirectory = "image-studio";
        # qemu-nbd, mounting and /etc/nixos writes need root. The HTTP server
        # still binds loopback and should be protected by a token/Tailscale.
        User = "root";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}