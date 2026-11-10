# Installation layout selector.
#
# The three supported layouts are:
#
#   nixos  – NixOS is the only operating system on the machine.
#   vm     – NixOS is the only operating system, with Windows 11 in a VM.
#   dual   – NixOS and Windows 11 are installed side by side.
#
# install/install.sh writes the selected mode to ../installation-mode.nix and
# creates the matching disk layout.  This module only applies the runtime
# pieces: libvirt for the VM, and the Windows boot/clock settings for dual
# boot.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.myInstall;

  windowsVmCreate = pkgs.writeShellScriptBin "windows-vm-create" ''
    export PATH="${
      lib.makeBinPath [
        pkgs.virt-manager
        pkgs.libvirt
        pkgs.qemu_kvm
        pkgs.coreutils
        pkgs.gawk
        pkgs.gnugrep
        pkgs.util-linux
      ]
    }:$PATH"
    export MYINSTALL_VM_ISO="${if cfg.vm.iso != null then cfg.vm.iso else ""}"
    export MYINSTALL_VM_MEMORY="${toString cfg.vm.memory}"
    export MYINSTALL_VM_VCPUS="${toString cfg.vm.vcpus}"
    export MYINSTALL_VM_DISK_SIZE="${cfg.vm.diskSize}"
    ${builtins.readFile ./windows-vm-create.sh}
  '';

  windowsBuild = pkgs.writeShellScriptBin "windows-build" ''
    export PATH="${
      lib.makeBinPath [
        pkgs.wimlib
        pkgs.p7zip
        pkgs.libisoburn
        pkgs.ntfs3g
        pkgs.chntpw
        pkgs.hivex
        pkgs.python3
        pkgs.coreutils
        pkgs.findutils
        pkgs.gawk
        pkgs.gnused
        pkgs.gnugrep
        pkgs.which
      ]
    }:$PATH"
    export WINDOWS_REPO="''${WINDOWS_REPO:-${cfg.windows.repo}}"
    ${builtins.readFile ./windows-build.sh}
  '';
in
{
  options.myInstall = {
    mode = lib.mkOption {
      type = lib.types.enum [
        "nixos"
        "vm"
        "dual"
      ];
      default = "nixos";
      description = ''
        Installation layout selected by `install/install.sh`.

        - `nixos`: NixOS only.
        - `vm`: NixOS only, with Windows 11 running in libvirt/QEMU.
        - `dual`: NixOS and Windows 11 installed on the same machine.
      '';
    };

    vm = {
      user = lib.mkOption {
        type = lib.types.str;
        default = "nixos";
        description = ''
          User added to the `libvirtd` group.  Use `windows-vm-create` or
          virt-manager to manage the Windows VM.
        '';
      };

      iso = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/var/lib/libvirt/images/Win11.iso";
        description = ''
          Default Windows 11 ISO for `windows-vm-create`.  The installer copies
          `--windows-iso` here.  If null, the helper searches the usual paths.
        '';
      };

      memory = lib.mkOption {
        type = lib.types.int;
        default = 8192;
        description = "Default guest memory in MiB for `windows-vm-create`.";
      };

      vcpus = lib.mkOption {
        type = lib.types.int;
        default = 4;
        description = "Default guest vCPU count for `windows-vm-create`.";
      };

      diskSize = lib.mkOption {
        type = lib.types.str;
        default = "80G";
        description = "Default qcow2 disk size for `windows-vm-create`.";
      };
    };

    dualBoot = {
      windowsEfiDeviceHandle = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "HD0b1";
        description = ''
          EDK2 device handle of the ESP that contains
          `\EFI\Microsoft\Boot\bootmgfw.efi`.

          Leave this null when NixOS and Windows share one ESP: systemd-boot
          detects Windows automatically.  Set it only when the installer had to
          create a separate ESP for NixOS.  To find the handle, enable
          `myInstall.dualBoot.separateEsp`, reboot, pick the EDK2 UEFI Shell,
          run `map -c`, and look for the handle whose `\EFI` directory contains
          `Microsoft`.
        '';
      };

      separateEsp = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether NixOS uses its own ESP instead of the Windows ESP.  This adds
          the EDK2 UEFI Shell to the boot menu so the Windows device handle can
          be discovered.
        '';
      };

      windowsTitle = lib.mkOption {
        type = lib.types.str;
        default = "Windows 11";
        description = "Title of the Windows entry in the systemd-boot menu.";
      };

      rtcLocalTime = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Tell Linux that the hardware clock uses local time, which is what
          Windows expects.  Disable this only if Windows is configured to use
          UTC.
        '';
      };
    };

    windows = {
      toolchain = lib.mkOption {
        type = lib.types.enum [
          "none"
          "native"
          "docker"
          "both"
        ];
        default = "native";
        description = ''
          How to provide the Windows 11 slim-image build toolchain.

          - `native`: install wimlib, 7-Zip, xorriso, ntfs-3g, chntpw, hivex,
            python3 and the `windows-build` wrapper on this machine.
          - `docker`: enable Docker and add `windows.user` to the docker
            group.
          - `both`: install the native packages and enable Docker.
          - `none`: do not install either path.
        '';
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "nixos";
        description = "User added to the docker group for the Docker toolchain.";
      };

      repo = lib.mkOption {
        type = lib.types.str;
        default = "/etc/nixos/windows";
        description = ''
          Location of the `windows/` toolkit used by `windows-build`.  The
          installer copies it to `/etc/nixos/windows`.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.mode == "vm") {
      virtualisation.libvirtd = {
        enable = true;
        qemu.swtpm.enable = true;
      };

      virtualisation.spiceUSBRedirection.enable = true;
      programs.virt-manager.enable = true;

      users.groups.libvirtd.members = [ cfg.vm.user ];

      environment.systemPackages = [
        windowsVmCreate
        pkgs.dnsmasq
      ];

      # libvirt ships the default NAT network but does not start it.  Do that
      # once, and mark it for autostart, so a fresh Windows VM has networking.
      systemd.services.libvirt-default-network = {
        description = "Start the libvirt default NAT network";
        wants = [ "libvirtd.service" ];
        after = [ "libvirtd.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if ! ${pkgs.libvirt}/bin/virsh net-list --name \
              | ${pkgs.gnugrep}/bin/grep -qx default; then
            ${pkgs.libvirt}/bin/virsh net-start default || true
          fi
          ${pkgs.libvirt}/bin/virsh net-autostart default || true
        '';
      };
    })

    (lib.mkIf (cfg.mode == "dual") {
      # Windows stores the RTC in local time unless it is configured for UTC.
      time.hardwareClockInLocalTime = lib.mkDefault cfg.dualBoot.rtcLocalTime;

      # Keep the shared ESP small and predictable.  Older generations remain
      # available through `nixos-rebuild --rollback` and the Nix store.
      boot.loader.systemd-boot.configurationLimit = lib.mkDefault 10;

      environment.systemPackages = with pkgs; [
        efibootmgr
        ntfs3g
      ];

      boot.loader.systemd-boot.windows = lib.optionalAttrs (cfg.dualBoot.windowsEfiDeviceHandle != null) {
        windows = {
          title = cfg.dualBoot.windowsTitle;
          efiDeviceHandle = cfg.dualBoot.windowsEfiDeviceHandle;
          sortKey = "z_windows";
        };
      };

      # Only useful when NixOS has its own ESP: it lets the user discover the
      # Windows ESP device handle once.
      boot.loader.systemd-boot.edk2-uefi-shell = lib.mkIf cfg.dualBoot.separateEsp {
        enable = true;
        sortKey = "z_edk2";
      };
    })

    (lib.mkIf (cfg.windows.toolchain == "native" || cfg.windows.toolchain == "both") {
      environment.systemPackages = with pkgs; [
        windowsBuild
        wimlib
        p7zip
        libisoburn
        ntfs3g
        chntpw
        hivex
        python3
        coreutils
        findutils
        gawk
        gnused
        gnugrep
        which
      ];
    })

    (lib.mkIf (cfg.windows.toolchain == "docker" || cfg.windows.toolchain == "both") {
      virtualisation.docker.enable = true;
      users.groups.docker.members = [ cfg.windows.user ];
      environment.systemPackages = [ pkgs.docker ];
    })
  ];
}
