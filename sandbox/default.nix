# Agent sandbox: a KVM microVM per task with a per-sandbox network.
#
# Docker isolates namespaces, not the kernel.  krunvm/libkrun boots a separate
# Linux kernel for each agent, so a compromised process inside has no path to
# the host's /proc, /sys, ZFS pool, libvirt disks or the Docker daemon.  The
# VMM also runs in its own network namespace: the host firewall drops every
# connection from the sandbox to the host and every connection between two
# sandboxes, while the host can still reach published guest ports.
#
# This is deliberately separate from myServices: project containers and
# untrusted agents should not share a daemon or a kernel.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.mySandbox;

  agentVm = pkgs.writeShellScriptBin "agent-vm" ''
    export PATH="${
      lib.makeBinPath [
        pkgs.krunvm
        pkgs.buildah
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.gawk
        pkgs.util-linux
        pkgs.iproute2
        pkgs.nftables
        pkgs.socat
        pkgs.procps
      ]
    }:$PATH"
    export MY_SANDBOX_CPUS="${toString cfg.cpus}"
    export MY_SANDBOX_MEM="${toString cfg.memory}"
    export MY_SANDBOX_IMAGE="${cfg.image}"
    export MY_SANDBOX_DNS="${cfg.dns}"
    export MY_SANDBOX_WORKSPACES="${cfg.workspaceRoot}"
    export MY_SANDBOX_SHARES="${cfg.sharedRoot}"
    export MY_SANDBOX_STATE="${cfg.stateRoot}"
    ${builtins.readFile ./agent-vm.sh}
  '';
in
{
  options.mySandbox = {
    enable = lib.mkEnableOption "the agent microVM sandbox";

    user = lib.mkOption {
      type = lib.types.str;
      default = "nixos";
      description = "User that owns the workspace and shared directories.";
    };

    cpus = lib.mkOption {
      type = lib.types.ints.between 1 8;
      default = 4;
      description = "Default vCPU count for agent microVMs.";
    };

    memory = lib.mkOption {
      type = lib.types.ints.between 256 16384;
      default = 4096;
      description = "Default guest memory in MiB for agent microVMs.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/library/debian:bookworm-slim";
      description = "Default OCI image used as the microVM root filesystem.";
    };

    dns = lib.mkOption {
      type = lib.types.str;
      default = "1.1.1.1";
      description = ''
        DNS resolver written to the guest's /etc/resolv.conf.  It is only
        reachable when the sandbox is started with `--online`.
      '';
    };

    workspaceRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/agent-workspaces";
      description = ''
        Directory created for agent workspaces.  Any other directory can still
        be passed to `agent-vm --workspace`, but sensitive paths are refused.
      '';
    };

    sharedRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/agent-shares";
      description = ''
        Directory for folders shared between the host and sandboxes, or
        explicitly between two sandboxes.  `agent-vm --share` accepts any
        non-sensitive path; this is the conventional place to keep them.
      '';
    };

    stateRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/agent-vm";
      description = ''
        Root-only state directory: sandbox metadata, published ports and
        shared-folder records.  The krunvm VM definitions live in root's own
        configuration directory.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # krunvm and buildah are runtime dependencies of the wrapper.  buildah
    # needs to run as root to mount the OCI image read-only before boot.
    environment.systemPackages = [
      agentVm
      pkgs.krunvm
      pkgs.buildah
      pkgs.nftables
      pkgs.iproute2
      pkgs.socat
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.workspaceRoot} 0750 ${cfg.user} users -"
      "d ${cfg.sharedRoot} 0770 ${cfg.user} users -"
      "d ${cfg.stateRoot} 0700 root root -"
      "d ${cfg.stateRoot}/state 0700 root root -"
      "d /run/agent-vm 0700 root root -"
      "d /run/agent-vm/log 0700 root root -"
      "d /run/agent-vm/pids 0700 root root -"
      "d /run/agent-vm/busy 0700 root root -"
      "d /run/agent-vm/ro 0700 root root -"
    ];

    # Guest egress is routed through the host; without forwarding the
    # per-sandbox network namespace has no route to the internet.
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

    # krunvm shells out to buildah, which on Linux looks for its signature
    # policy and registries in /etc/containers.  NixOS does not create those
    # files, so image pulls fail with "no policy.json file found".
    environment.etc."containers/policy.json".text = ''
      {
        "default": [ { "type": "insecureAcceptAnything" } ]
      }
    '';
    environment.etc."containers/registries.conf".text = ''
      unqualified-search-registries = ["docker.io"]
    '';
  };
}
