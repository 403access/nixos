# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, lib, pkgs, ... }:

{

  # === ZFS ===
  boot.supportedFilesystems = [ "zfs" ];
  #boot.kernelPackages = pkgs.linuxPackages_6_10;
  #boot.zfs.package = pkgs.zfsStable.compatibleLinuxPackages_6_10;
  boot.kernelModules = [ "zfs" ];
  boot.initrd.supportedFilesystems = [ "zfs" ];
  boot.initrd.kernelModules = [ "zfs" ];
  # Ensure your machine has a stable hostId (4 bytes hex string)
  networking.hostId = "c0debabe";
  # Automatically import your ZFS pool on boot
  boot.zfs.extraPools = [ "tank" ];
  boot.zfs.forceImportRoot = true;  # da es kein root-pool ist
  boot.zfs.forceImportAll = true;    # erzwingt Import aller Pools
  # ZFS services
  services.zfs.trim.enable = true;
  services.zfs.autoScrub.enable = true;
  services.zfs = {
#    autoImport.enable = true;
    autoSnapshot.enable = false;  # unless you want snapshots
  };
#  fileSystems."/mnt/tank" = {
#    device = "tank";
#    fsType = "zfs";
#    options = [ "zfsutil" ];
#  };

  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./nixos-control.nix
      ./desktop
    ];

  # Choose the desktop profile.  `xfce` preserves the original setup;
  # `rice`, `plasma`, `hyprland`, and `gnome` are the themed alternatives.
  myDesktop = {
    enable = true;
    profile = "xfce";
    user = "nixos";
    # GTK theme family: "catppuccin" (default) or "whitesur".
    gtkTheme = "whitesur";
    whiteSur = {
      variant = "dark";      # light | dark
      accent = "blue";       # default | blue | purple | pink | red | orange | yellow | green | grey
      icons = true;          # WhiteSur icons; false keeps Papirus-Dark
      cursors = true;        # WhiteSur cursors; false keeps Catppuccin
      plank = true;          # WhiteSur Plank dock
    };
  };

  nixpkgs.config.allowUnfree = true;

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Sleep and power management
  #systemd.targets.sleep.enable = false;
  #systemd.targets.suspend.enable = false;
  #systemd.targets.hibernate.enable = false;
  #systemd.targets.hybrid-sleep.enable = false;

  #networking.hostName = "nixos"; # Define your hostname.

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 3000 3389 ];
  }; 

  # Remote management API used by the iOS app. The server listens on
  # 127.0.0.1:8787 and is exposed over Tailscale Serve (HTTPS).
  services.nixos-control.enable = true;

  # Private networking for the phone and automatic HTTPS for the API.
  services.tailscale.enable = true;
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

 networking.nameservers = [
     # Google DNS
     "8.8.8.8"
     "8.8.4.4"
  ];
  # Pick only one of the below networking options.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  # networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.

  # Set your time zone.
  time.timeZone = "Europe/Amsterdam";

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Select internationalisation properties.
  # i18n.defaultLocale = "en_US.UTF-8";
  console = {
  #   font = "Lat2-Terminus16";
    keyMap = "de";
  #   useXkbConfig = true; # use xkb.options in tty.
  };

  # Enable Hyprland
  #programs.hyprland.enable = true;
  #programs.hyprland.xwayland.enable = true; 

#  environment.sessionVariables.WLR_NO_HARDWARE_CURSORS = "1";
#  environment.sessionVariables.NIXOS_OZONE_WL = "1";
#  hardware.nvidia.modesetting.enable = true;

  # Enable the X11 windowing system.  The selected desktop profile in
  # ./desktop owns the display manager, desktop environment and xrdp
  # window-manager command.
  services.xrdp.enable = true;

  systemd.targets.sleep.enable = lib.mkForce false;
  systemd.targets.suspend.enable = lib.mkForce false;
  systemd.targets.hibernate.enable = lib.mkForce false;
  systemd.targets.hybrid-sleep.enable = lib.mkForce false;

  powerManagement.enable = false;

systemd.sleep.extraConfig = ''
  AllowSuspend=no
  AllowHibernation=no
  AllowHybridSleep=no
  AllowSuspendThenHibernate=no
'';


#  systemd.extraConfig = {
#    "sleep.target" = {
#      wantedBy = [ ];
#      requiredBy = [ ];
#      aliases = [ ];
#    };
#    "suspend.target" = {
#      wantedBy = [ ];
#      requiredBy = [ ];
#      aliases = [ ];
#    };
#    "hibernate.target" = {
#      wantedBy = [ ];
#      requiredBy = [ ];
#      aliases = [ ];
#    };
#    "hybrid-sleep.target" = {
#      wantedBy = [ ];
#      requiredBy = [ ];
#      aliases = [ ];
#    };
#  };

  # Sleep and power management
  services.logind.extraConfig = ''
    HandleSuspendKey=ignore
    HandleLidSwitch=ignore
    HandleLidSwitchDocked=ignore
    IdleAction=ignore
  '';

services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "NixOS Samba Server";
        "netbios name" = "nixos";
        "security" = "user";

        # macOS VFS extensions
        "vfs objects" = "catia fruit streams_xattr";
        "fruit:aappl" = "yes";
        "fruit:metadata" = "stream";
        "fruit:model" = "MacSamba";
        "fruit:posix_rename" = "yes";
        "fruit:veto_appledouble" = "no";
        "fruit:wipe_intentionally_left_blank_rf" = "yes";
        "fruit:delete_empty_adfiles" = "yes";

        # Enable Apple SMB2/SMB3 file locking and extended attribute support
        "ea support" = "yes";
        "store dos attributes" = "yes";
        "map archive" = "no";
        "map hidden" = "no";
        "map readonly" = "no";
        "map system" = "no";     
      };

      # Full System Share
      "root" = {
        "path" = "/";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "force user" = "nixos";
      };

      # Dedicated Tank Share
      "tank" = {
        "path" = "/mnt/tank";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "force user" = "root";
      };
    };
  };

  

  # Keyboard layout is set by the desktop module.

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  # services.pulseaudio.enable = true;
  # OR
  # services.pipewire = {
  #   enable = true;
  #   pulse.enable = true;
  # };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
    users.users.nixos = {
      isNormalUser = true;
      password = "nixos";
      extraGroups = [ "wheel" "networkmanager" ]; # Enable ‘sudo’ for the user.
  #   packages = with pkgs; [
  #     tree
  #   ];
    };

  # programs.firefox.enable = true;

# Enable nix-ld for dynamically linked executables like VS Code Server
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    stdenv.cc.cc.lib
    zlib
    glibc
    openssl
    icu
    libxml2
    curl
  ];

  # List packages installed in system profile.
  # You can use https://search.nixos.org/ to find more packages (and options).
    environment.systemPackages = with pkgs; [
  #   vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
  #   wget
      wget git nano vim firefox
      sassc libsass
      glib glib.dev
      libxml2

      # virtual machine
      swtpm virtio-win qemu quickemu

      # remote access / management
      tailscale

      # backup
      jotta-cli
      rclone #rclone-ui

      # file system
      zfs
      gptfdisk

      # windows
      #wimtools
      wimlib ntfs3g gptfdisk util-linux parted

      # Bluetooth, e.g. for Logitech Mouse
      solaar    

      vlc

      # Hyprland
#      kitty
#      wofi
#      waybar
#      kdePackages.dolphin
#      wl-clipboard
#      xdg-utils

#      (waybar.overrideAttrs (oldAttrs: {
#         mesonFlags = oldAttrs.mesonFlags ++ [ "-Dexperimental=true"];
#        })
#      )

     # Hyprland - Notifications are installed by the rice/hyprland profiles.
#     libnotify
     
     # Hyprland - Wallpaper
#    swww
    ];

# Hyprland configs
#security.polkit.enable = true;
#services.dbus.enable = true;
#xdg.portal.enable = true;
#xdg.portal.extraPortals = [
#pkgs.xdg-desktop-portal-hyprland
#];
#hardware.graphics.enable = true;

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;
services.openssh = {
  enable = true;
  ports = [ 22 ];
  settings = {
    PasswordAuthentication = true;
    AllowUsers = null; # Allows all users by default. Can be [ "user1" "user2" ]
    UseDns = true;
    X11Forwarding = false;
    PermitRootLogin = "prohibit-password"; # "yes", "without-password", "prohibit-password", "forced-commands-only", "no"
  };
};


  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.05"; # Did you read the comment?

}

