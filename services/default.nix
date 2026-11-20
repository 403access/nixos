# Isolated Docker services for projects.
#
# Docker is the right tool for long-running, trusted services.  The important
# part is what it is *not* allowed to do: the desktop user is deliberately not
# in the `docker` group (that is root-equivalent), inter-container
# communication is off, containers get no new privileges, and project files
# are the only writable host paths a compose file can reach.
#
# Untrusted agents use mySandbox (KVM microVMs) instead.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.myServices;

  projectUp = pkgs.writeShellScriptBin "project-up" ''
    set -euo pipefail
    project="''${1:-}"
    case "$project" in
      '' | *[!A-Za-z0-9_-]*)
        printf 'usage: project-up NAME\n' >&2
        exit 2
        ;;
    esac
    dir="${cfg.dataRoot}/$project"
    [ -d "$dir" ] || { printf 'no such project: %s\n' "$project" >&2; exit 2; }
    compose="$dir/compose.yaml"
    [ -f "$compose" ] || compose="$dir/compose.yml"
    [ -f "$compose" ] || { printf '%s has no compose.yaml\n' "$dir" >&2; exit 2; }
    exec ${pkgs.docker-compose}/bin/docker-compose \
      --project-directory "$dir" -f "$compose" up -d
  '';

  projectDown = pkgs.writeShellScriptBin "project-down" ''
    set -euo pipefail
    project="''${1:-}"
    case "$project" in
      '' | *[!A-Za-z0-9_-]*)
        printf 'usage: project-down NAME\n' >&2
        exit 2
        ;;
    esac
    dir="${cfg.dataRoot}/$project"
    compose="$dir/compose.yaml"
    [ -f "$compose" ] || compose="$dir/compose.yml"
    [ -f "$compose" ] || { printf '%s has no compose.yaml\n' "$dir" >&2; exit 2; }
    exec ${pkgs.docker-compose}/bin/docker-compose \
      --project-directory "$dir" -f "$compose" down
  '';

  projectLogs = pkgs.writeShellScriptBin "project-logs" ''
    set -euo pipefail
    project="''${1:-}"
    case "$project" in
      '' | *[!A-Za-z0-9_-]*)
        printf 'usage: project-logs NAME [SERVICE]\n' >&2
        exit 2
        ;;
    esac
    dir="${cfg.dataRoot}/$project"
    compose="$dir/compose.yaml"
    [ -f "$compose" ] || compose="$dir/compose.yml"
    [ -f "$compose" ] || { printf '%s has no compose.yaml\n' "$dir" >&2; exit 2; }
    shift
    exec ${pkgs.docker-compose}/bin/docker-compose \
      --project-directory "$dir" -f "$compose" logs -f "$@"
  '';

  projectList = pkgs.writeShellScriptBin "project-list" ''
    set -euo pipefail
    for dir in ${cfg.dataRoot}/*/; do
      [ -d "$dir" ] || continue
      name="$(basename "$dir")"
      if [ -f "$dir/compose.yaml" ] || [ -f "$dir/compose.yml" ]; then
        printf '%s\n' "$name"
      fi
    done
  '';
in
{
  options.myServices = {
    enable = lib.mkEnableOption "isolated Docker project services";

    user = lib.mkOption {
      type = lib.types.str;
      default = "nixos";
      description = ''
        User allowed to run the project-up/down/logs helpers through sudo.
        The user is intentionally *not* added to the docker group.
      '';
    };

    dataRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/projects";
      description = ''
        One directory per project, each containing a compose file and its
        data.  Docker itself keeps images in /var/lib/docker.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.docker = {
      enable = true;
      daemon.settings = {
        # Restarting the daemon does not kill running projects.
        "live-restore" = true;
        # Containers on the default bridge cannot talk to each other.
        "icc" = false;
        # Any container that gains a setuid binary still cannot escalate.
        "no-new-privileges" = true;
        # Bounded, rotating logs instead of unbounded json files.
        "log-driver" = "local";
      };
    };

    environment.systemPackages = [
      pkgs.docker
      pkgs.docker-compose
      projectUp
      projectDown
      projectLogs
      projectList
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataRoot} 0750 root root -"
    ];

    # The helpers validate the project name and live under dataRoot, so they
    # are safe to expose without making the user a docker-group member.
    security.sudo.extraRules = [
      {
        users = [ cfg.user ];
        commands = map (script: {
          command = "${script}/bin/${script.name}";
          options = [ "NOPASSWD" ];
        }) [
          projectUp
          projectDown
          projectLogs
          projectList
        ];
      }
    ];
  };
}