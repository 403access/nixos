# Agent sandbox: a KVM microVM per task instead of a shared-kernel container.
#
# Docker isolates namespaces, not the kernel.  krunvm/libkrun boots a separate
# Linux kernel for each agent, so a compromised process inside has no path to
# the host's /proc, /sys, ZFS pool, libvirt disks or the Docker daemon.  The
# guest sees one workspace directory and, unless --online is passed, no
# network at all.
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
      ]
    }:$PATH"
    export MY_SANDBOX_CPUS="${toString cfg.cpus}"
    export MY_SANDBOX_MEM="${toString cfg.memory}"
    export MY_SANDBOX_IMAGE="${cfg.image}"
    export MY_SANDBOX_WORKSPACES="${cfg.workspaceRoot}"
    ${builtins.readFile ./agent-vm.sh}
  '';
in
{
  options.mySandbox = {
    enable = lib.mkEnableOption "the agent microVM sandbox";

    user = lib.mkOption {
      type = lib.types.str;
      default = "nixos";
      description = "User that owns the workspace directory.";
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

    workspaceRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/agent-workspaces";
      description = ''
        Directory created for agent workspaces.  Any other directory can still
        be passed to `agent-vm --workspace`, but sensitive paths are refused.
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
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.workspaceRoot} 0750 ${cfg.user} users -"
    ];

    # /dev/kvm access.  agent-vm itself runs through sudo, but the group keeps
    # direct qemu/virt-manager use working for the same user.
    users.users = lib.mkIf (lib.hasAttr cfg.user config.users.users) {
      ${cfg.user} = {
        extraGroups = [ "kvm" ];
      };
    };
  };
}