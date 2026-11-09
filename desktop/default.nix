# A small, opinionated desktop-profile selector.
#
# The machine keeps its existing XFCE setup by default.  Set
# `myDesktop.profile` to try one of the themed alternatives:
#
#   xfce      – the original XFCE desktop (safe fallback)
#   rice      – Catppuccin i3 + polybar + picom (works over VNC and xrdp)
#   plasma    – KDE Plasma 6 with the Catppuccin KDE theme
#   hyprland  – Hyprland + waybar + mako (Wayland, real hardware)
#
# Everything is declarative: the theme files live in `desktop/rice` and
# `desktop/hyprland`, and are linked into the user's home from the Nix store.
{ config, lib, pkgs, ... }:

let
  cfg = config.myDesktop;

  flavourDir = cfg.flavour; # mocha, macchiato, frappe, latte

  cursorOutput = "${flavourDir}Dark";
  cursorName = "catppuccin-${flavourDir}-dark-cursors";
  gtkThemeName = "catppuccin-${cfg.flavour}-${cfg.accent}-standard";

  catppuccinGtk = pkgs.catppuccin-gtk.override {
    variant = cfg.flavour;
    accents = [ cfg.accent ];
    size = "standard";
  };

  catppuccinCursors = pkgs.catppuccin-cursors.${cursorOutput};

  papirus = pkgs.catppuccin-papirus-folders.override {
    flavor = cfg.flavour;
    accent = cfg.accent;
  };

  wallpaper = pkgs.runCommand "nixos-rice-wallpaper.png" {
    nativeBuildInputs = [ pkgs.librsvg ];
  } ''
    rsvg-convert -w 2560 -h 1600 -o "$out" ${./wallpaper.svg}
  '';

  # Catppuccin's SDDM theme.  25.11 (theme 1.1.x) added an `accent`
  # argument; 25.05 (1.0.x) only has a per-flavour theme.  Choose the
  # supported interface from the package version.
  sddmBaseArgs = {
    flavor = cfg.flavour;
    background = cfg.wallpaper;
    font = "Inter";
    fontSize = "10";
  };
  sddmSupportsAccent = lib.versionAtLeast pkgs.catppuccin-sddm.version "1.1";
  catppuccinSddm =
    if sddmSupportsAccent
    then pkgs.catppuccin-sddm.override (sddmBaseArgs // { accent = cfg.accent; })
    else pkgs.catppuccin-sddm.override sddmBaseArgs;
  sddmThemeName =
    if sddmSupportsAccent then "catppuccin-${cfg.flavour}-${cfg.accent}"
    else "catppuccin-${cfg.flavour}";

in
{
  imports = [
    ./profiles/xfce.nix
    ./profiles/plasma.nix
    ./profiles/rice.nix
    ./profiles/hyprland.nix
  ];

  options.myDesktop = {
    enable = lib.mkEnableOption "the themed desktop profiles";

    profile = lib.mkOption {
      type = lib.types.enum [ "xfce" "rice" "plasma" "hyprland" ];
      default = "xfce";
      description = ''
        Which desktop to enable. `xfce` preserves the original setup;
        `rice` is a Catppuccin i3 desktop that also works over VNC and
        xrdp; `plasma` is KDE Plasma 6; `hyprland` is a Wayland desktop
        for real hardware.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "nixos";
      description = "User whose home directory receives the profile dotfiles.";
    };

    home = lib.mkOption {
      type = lib.types.str;
      default = "/home/${cfg.user}";
      description = "Home directory of `myDesktop.user`.";
    };

    flavour = lib.mkOption {
      type = lib.types.enum [ "mocha" "macchiato" "frappe" "latte" ];
      default = "mocha";
      description = "Catppuccin flavour used by the themed profiles.";
    };

    accent = lib.mkOption {
      type = lib.types.enum [
        "blue" "flamingo" "green" "lavender" "maroon" "mauve" "peach"
        "pink" "red" "rosewater" "sapphire" "sky" "teal" "yellow"
      ];
      default = "blue";
      description = "Catppuccin accent colour.";
    };

    wallpaper = lib.mkOption {
      type = lib.types.path;
      default = wallpaper;
      defaultText = lib.literalExpression "desktop/wallpaper.svg (built to PNG)";
      description = "Wallpaper used by the themed desktops and SDDM.";
    };

    enableDisplayManager = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable SDDM (or lightdm for XFCE).  Disable this on the OrbStack
        test machine, which starts its session from a systemd VNC unit.
      '';
    };

    # Internal facts consumed by the VM configuration.
    sessionCommand = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Command that starts the selected graphical session.";
    };

    sessionType = lib.mkOption {
      type = lib.types.enum [ "x11" "wayland" ];
      default = "x11";
      description = "Display server used by the selected session.";
    };

    supportedOverVnc = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether the selected session can run on an X11 VNC display.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.users.users ? ${cfg.user};
        message = "myDesktop.user '${cfg.user}' does not exist.";
      }
    ];

    # --- Shared look and feel -------------------------------------------
    fonts.packages = with pkgs; [
      inter
      nerd-fonts.jetbrains-mono
      noto-fonts
      noto-fonts-color-emoji
      dejavu_fonts
      liberation_ttf
    ];

    fonts.fontconfig.defaultFonts = {
      sansSerif = [ "Inter" "Noto Sans" "DejaVu Sans" ];
      monospace = [ "JetBrainsMono Nerd Font" "DejaVu Sans Mono" ];
      emoji = [ "Noto Color Emoji" ];
    };

    environment.systemPackages = with pkgs; [
      # Theme assets
      catppuccinGtk
      catppuccinCursors
      papirus
      (catppuccin-kvantum.override {
        variant = cfg.flavour;
        accent = cfg.accent;
      })
      catppuccin-qt5ct
      kdePackages.qtstyleplugin-kvantum

      # Common desktop tools
      firefox
      kitty
      rofi
      xfce.thunar
      xfce.tumbler
      pavucontrol
      brightnessctl
      playerctl
      pamixer
      fastfetch
      btop
      xclip
      clipmenu
      lxappearance
      qt6Packages.qt6ct
      xdg-utils
      xdg-user-dirs
      adwaita-icon-theme
      hicolor-icon-theme
      (writeShellScriptBin "desktop-polkit-agent" ''
        exec ${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1
      '')
    ] ++ lib.optionals
      (cfg.enableDisplayManager && cfg.profile != "xfce")
      [ catppuccinSddm ];

    environment.sessionVariables = {
      GTK_THEME = gtkThemeName;
      XCURSOR_THEME = cursorName;
      XCURSOR_SIZE = "24";
    };

    environment.etc."gtk-2.0/gtkrc".text = ''
      gtk-theme-name = "${gtkThemeName}"
      gtk-icon-theme-name = "Papirus-Dark"
      gtk-font-name = "Inter 10"
      gtk-cursor-theme-name = "${cursorName}"
      gtk-cursor-theme-size = 24
    '';

    environment.etc."gtk-3.0/settings.ini".text = ''
      [Settings]
      gtk-theme-name=${gtkThemeName}
      gtk-icon-theme-name=Papirus-Dark
      gtk-font-name=Inter 10
      gtk-cursor-theme-name=${cursorName}
      gtk-cursor-theme-size=24
      gtk-application-prefer-dark-theme=true
      gtk-enable-animations=true
    '';

    environment.etc."gtk-4.0/settings.ini".text = ''
      [Settings]
      gtk-theme-name=${gtkThemeName}
      gtk-icon-theme-name=Papirus-Dark
      gtk-font-name=Inter 10
      gtk-cursor-theme-name=${cursorName}
      gtk-cursor-theme-size=24
      gtk-application-prefer-dark-theme=true
      gtk-enable-animations=true
    '';

    # Qt applications use Kvantum (via qt6ct) in the non-Plasma profiles.
    environment.etc."xdg/Kvantum/kvantum.kvconfig".text = ''
      [General]
      theme=catppuccin-${cfg.flavour}-${cfg.accent}
    '';

    environment.etc."xdg/qt6ct/qt6ct.conf".text = ''
      [Appearance]
      style=kvantum
      icon_theme=Papirus-Dark
      standard_dialogs=default
    '';

    # Shared plumbing that every desktop expects.
    security.polkit.enable = lib.mkDefault true;
    services.dbus.enable = lib.mkDefault true;
    programs.dconf.enable = lib.mkDefault true;
    hardware.graphics.enable = lib.mkDefault true;

    services.pipewire = {
      enable = lib.mkDefault true;
      alsa.enable = lib.mkDefault true;
      alsa.support32Bit = lib.mkDefault true;
      pulse.enable = lib.mkDefault true;
    };

    services.libinput.enable = lib.mkDefault true;
    services.upower.enable = lib.mkDefault true;
    services.udisks2.enable = lib.mkDefault true;
    services.gvfs.enable = lib.mkDefault true;

    # German keyboard, matching the rest of the machine.
    services.xserver.xkb.layout = "de";
    services.xserver.xkb.variant = "";

    # Only the XFCE profile uses lightdm; the others use SDDM or no
    # display manager at all (the OrbStack VM starts its session directly).
    services.xserver.displayManager.lightdm.enable =
      lib.mkForce (cfg.profile == "xfce" && cfg.enableDisplayManager);

    # --- SDDM for the non-XFCE profiles ---------------------------------
    services.displayManager.sddm = lib.mkIf
      (cfg.enableDisplayManager && cfg.profile != "xfce")
      {
        enable = true;
        theme = sddmThemeName;
        settings = {
          Theme = {
            Current = sddmThemeName;
            CursorTheme = cursorName;
            CursorSize = 24;
          };
          General = {
            Numlock = "on";
          };
          Wayland = {
            EnableHiDPI = true;
          };
        };
        extraPackages = with pkgs.kdePackages; [ qtsvg qt5compat ];
      };
  };
}
