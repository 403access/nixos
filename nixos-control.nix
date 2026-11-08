{ config, lib, pkgs, ... }:

let
  cfg = config.services.nixos-control;
  version = "0.1.0";

  package = pkgs.buildGoModule {
    pname = "nixos-control";
    inherit version;
    src = ./server;
    vendorHash = null;
    ldflags = [
      "-s"
      "-w"
      "-X main.version=${version}"
    ];
    meta = with lib; {
      description = "Small authenticated API for monitoring and managing a NixOS machine";
      mainProgram = "nixos-control";
    };
  };

  serverArgs = [
    "${package}/bin/nixos-control"
    "--listen" "${cfg.address}:${toString cfg.port}"
    "--token-file" cfg.tokenFile
    "--allow-rebuild=${lib.boolToString cfg.allowRebuild}"
    "--allow-power=${lib.boolToString cfg.allowPower}"
  ] ++ lib.optionals (cfg.flake != null) [ "--flake" cfg.flake ];

  tokenScript = pkgs.writeShellScriptBin "nixos-control-token" ''
    if [ "$(id -u)" -ne 0 ]; then
      echo "Run this command with sudo to read the API token." >&2
      exit 1
    fi
    cat ${lib.escapeShellArg cfg.tokenFile}
  '';
in
{
  options.services.nixos-control = {
    enable = lib.mkEnableOption "the NixOS Control API server";

    address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address the API server listens on. Keep the default when exposing the
        server through Tailscale Serve.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8787;
      description = "Port the API server listens on.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open the API port in the firewall. Only needed when connecting directly
        over the LAN instead of through Tailscale Serve.
      '';
    };

    tokenFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nixos-control/token";
      description = ''
        File containing the bearer token. A random token is generated
        automatically when the file does not exist.
      '';
    };

    flake = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/etc/nixos#nixos";
      description = ''
        When set, rebuild actions run
        `nixos-rebuild <action> --flake <value>`.
      '';
    };

    allowRebuild = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Allow the app to trigger nixos-rebuild actions.";
    };

    allowPower = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Allow the app to reboot and shut down the machine.";
    };

    tailscaleServe = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Expose the API through Tailscale Serve with automatic HTTPS. Requires
          services.tailscale to be enabled and HTTPS certificates to be enabled
          for the tailnet in the Tailscale admin console.
        '';
      };

      httpsPort = lib.mkOption {
        type = lib.types.port;
        default = 443;
        description = "HTTPS port used by Tailscale Serve.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.tokenFile != "";
        message = "services.nixos-control.tokenFile must not be empty.";
      }
    ];

    systemd.services.nixos-control = {
      description = "NixOS Control API";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      # Rebuild jobs run as children of this service. Avoid having
      # switch-to-configuration restart this unit mid-rebuild and kill the
      # nixos-rebuild process. Restart it manually after changing the server.
      restartIfChanged = false;

      environment = {
        HOME = "/root";
        PATH = lib.mkForce "${config.system.path}/bin:${config.system.path}/sbin";
      } // lib.optionalAttrs (config.nix.nixPath != []) {
        NIX_PATH = lib.concatStringsSep ":" config.nix.nixPath;
      };

      preStart = ''
        token_file=${lib.escapeShellArg cfg.tokenFile}
        token_dir=$(dirname "$token_file")
        if [ ! -d "$token_dir" ]; then
          mkdir -p -m 0700 "$token_dir"
        fi
        if [ ! -s "$token_file" ]; then
          (umask 077; ${pkgs.openssl}/bin/openssl rand -hex 32 > "$token_file")
        fi
      '';

      serviceConfig = {
        ExecStart = lib.concatMapStringsSep " " lib.escapeShellArg serverArgs;
        StateDirectory = "nixos-control";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "nixos-control";
        Restart = "on-failure";
        RestartSec = 2;
        UMask = "0077";

        # Runs as root because it talks to systemd, reads the journal, manages
        # ZFS and can trigger nixos-rebuild. Access is restricted to the local
        # interface and protected by a bearer token.
        PrivateTmp = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
      };
    };

    systemd.services.nixos-control-tailscale-serve = lib.mkIf
      (cfg.tailscaleServe.enable && config.services.tailscale.enable)
      {
        description = "Expose NixOS Control through Tailscale Serve";
        wantedBy = [ "multi-user.target" ];
        after = [
          "tailscaled.service"
          "nixos-control.service"
          "network-online.target"
        ];
        wants = [
          "nixos-control.service"
          "network-online.target"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 30;
          ExecStart = "${pkgs.tailscale}/bin/tailscale serve --bg --https=${toString cfg.tailscaleServe.httpsPort} http://127.0.0.1:${toString cfg.port}";
        };
      };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    environment.systemPackages = [
      package
      tokenScript
    ];
  };
}
