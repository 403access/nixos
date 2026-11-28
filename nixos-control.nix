{ config, lib, pkgs, ... }:

let
  cfg = config.services.nixos-control;
  version = "0.1.0";

  package = pkgs.rustPlatform.buildRustPackage {
    pname = "nixos-control";
    inherit version;
    src = lib.fileset.toSource {
      root = ./server;
      fileset = lib.fileset.unions [
        ./server/Cargo.toml
        ./server/Cargo.lock
        ./server/src
        ./server/tests
      ];
    };
    cargoLock.lockFile = ./server/Cargo.lock;

    # hidapi's Linux hidraw backend talks to libudev.
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.udev ];

    # Embed the module version instead of the default "dev".
    env = {
      NIXOS_CONTROL_VERSION = version;
    };

    meta = with lib; {
      description = "Small authenticated API for monitoring and managing a NixOS machine";
      mainProgram = "nixos-control";
    };
  };

  serverArgs = [
    "${package}/bin/nixos-control"
    "--listen" "${cfg.address}:${toString cfg.port}"
    "--token-file" cfg.tokenFile
    "--activity-file" "/var/lib/nixos-control/activity.jsonl"
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

  # `tailscale serve` exits 1 while the host is logged out. Treat that as a
  # skipped setup step so it cannot make every nixos-rebuild switch fail.
  tailscaleServeScript = pkgs.writeShellScript "nixos-control-tailscale-serve" ''
    set +e
    output=$(${pkgs.tailscale}/bin/tailscale serve --bg \
      --https=${toString cfg.tailscaleServe.httpsPort} \
      http://127.0.0.1:${toString cfg.port} 2>&1)
    code=$?
    printf '%s\n' "$output"
    if [ "$code" -eq 0 ]; then
      exit 0
    fi
    case "$output" in
      *"Logged out."*|*"logged out"*|*"not logged in"*)
        echo "Tailscale is logged out; skipping serve setup." >&2
        exit 0
        ;;
    esac
    exit "$code"
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
        Open the API port in the firewall on all interfaces. Only needed when
        connecting directly over the LAN or through a router VPN such as
        FRITZ!Box WireGuard. If the host is reachable from untrusted networks,
        prefer binding to a LAN address and a per-interface firewall rule.
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

    commandLog = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Record interactive bash and zsh commands with start time, duration,
          exit status, TTY and working directory in
          `~/.local/state/nixos-control/commands.jsonl`. The Sessions view reads
          this file so it can show execution times and whether a command
          succeeded or failed. The log is private to each user (mode 0600) and
          is read by the root API service. Disable to turn off shell
          integration.
        '';
      };
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

    # Interactive shell audit log for the Sessions view.
    programs.bash.interactiveShellInit = lib.mkIf cfg.commandLog.enable (
      builtins.readFile ./shell/command-log.bash
    );
    programs.zsh.interactiveShellInit = lib.mkIf cfg.commandLog.enable (
      builtins.readFile ./shell/command-log.zsh
    );

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
        PATH = lib.mkForce "${lib.makeBinPath [ pkgs.iproute2 ]}:${config.system.path}/bin:${config.system.path}/sbin";
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
          ExecStart = tailscaleServeScript;
        };
      };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    environment.systemPackages = [
      package
      tokenScript
    ];
  };
}
