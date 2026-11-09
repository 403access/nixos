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
# The GTK theme family is independent of the desktop profile: keep the
# Catppuccin look, or switch `myDesktop.gtkTheme` to `whitesur` for the
# macOS-like WhiteSur theme (https://github.com/vinceliuice/WhiteSur-gtk-theme).
#
# Everything is declarative: the theme files live in `desktop/rice` and
# `desktop/hyprland`, and are linked into the user's home from the Nix store.
{ config, lib, pkgs, ... }:

let
  cfg = config.myDesktop;

  useWhiteSur = cfg.gtkTheme == "whitesur";

  flavourDir = cfg.flavour; # mocha, macchiato, frappe, latte

  catppuccinCursorOutput = "${flavourDir}Dark";
  catppuccinCursorName = "catppuccin-${flavourDir}-dark-cursors";
  catppuccinGtkThemeName = "catppuccin-${cfg.flavour}-${cfg.accent}-standard";

  catppuccinGtk = pkgs.catppuccin-gtk.override {
    variant = cfg.flavour;
    accents = [ cfg.accent ];
    size = "standard";
  };

  catppuccinCursors = pkgs.catppuccin-cursors.${catppuccinCursorOutput};

  papirus = pkgs.catppuccin-papirus-folders.override {
    flavor = cfg.flavour;
    accent = cfg.accent;
  };

  # WhiteSur names its themes after the variant and accent, e.g.
  # `WhiteSur-Dark-blue`.  Icon themes use the same suffix in lower case and
  # do not have a `blue` accent, so blue maps to their `default` icons.
  whiteSurIconAccent =
    if cfg.whiteSur.accent == "blue" then "default" else cfg.whiteSur.accent;

  whiteSurGtk = pkgs.whitesur-gtk-theme.override {
    colorVariants = [ cfg.whiteSur.variant ];
    themeVariants = [ cfg.whiteSur.accent ];
  };

  whiteSurGtkThemeName =
    "WhiteSur"
    + (if cfg.whiteSur.variant == "dark" then "-Dark" else "-Light")
    + lib.optionalString (cfg.whiteSur.accent != "default") "-${cfg.whiteSur.accent}";

  whiteSurIcons = pkgs.whitesur-icon-theme.override {
    themeVariants = [ whiteSurIconAccent ];
  };

  whiteSurIconThemeName =
    "WhiteSur"
    + lib.optionalString (whiteSurIconAccent != "default") "-${whiteSurIconAccent}"
    + (if cfg.whiteSur.variant == "dark" then "-dark" else "-light");

  # Resolved names and packages shared with the individual profiles.
  gtkThemeName = if useWhiteSur then whiteSurGtkThemeName else catppuccinGtkThemeName;
  iconThemeName =
    if useWhiteSur && cfg.whiteSur.icons then whiteSurIconThemeName
    else "Papirus-Dark";
  cursorName =
    if useWhiteSur && cfg.whiteSur.cursors then "WhiteSur-cursors"
    else catppuccinCursorName;

  # Catppuccin is always treated as a dark theme (as before); WhiteSur follows
  # the selected variant so GTK does not swap the light theme for its dark
  # variant behind our back.
  preferDarkTheme = !(useWhiteSur && cfg.whiteSur.variant == "light");

  themePackages =
    if useWhiteSur then
      [ whiteSurGtk ]
      ++ lib.optional cfg.whiteSur.icons whiteSurIcons
      ++ lib.optional cfg.whiteSur.cursors pkgs.whitesur-cursors
      ++ lib.optional (!cfg.whiteSur.icons) papirus
      ++ lib.optional (!cfg.whiteSur.cursors) catppuccinCursors
    else
      [ catppuccinGtk catppuccinCursors papirus ];

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

    gtkTheme = lib.mkOption {
      type = lib.types.enum [ "catppuccin" "whitesur" ];
      default = "catppuccin";
      description = ''
        GTK, icon and cursor theme family.  `catppuccin` follows `flavour`
        and `accent`; `whitesur` installs the macOS-like
        [WhiteSur](https://github.com/vinceliuice/WhiteSur-gtk-theme)
        theme, configured by `whiteSur.*`.
      '';
    };

    whiteSur = lib.mkOption {
      default = { };
      description = "WhiteSur theme settings for `myDesktop.gtkTheme = \"whitesur\"`.";
      type = lib.types.submodule {
        options = {
          variant = lib.mkOption {
            type = lib.types.enum [ "light" "dark" ];
            default = "dark";
            description = "WhiteSur light or dark variant.";
          };

          accent = lib.mkOption {
            type = lib.types.enum [
              "default" "blue" "purple" "pink" "red" "orange" "yellow"
              "green" "grey"
            ];
            default = "blue";
            description = "WhiteSur accent colour.";
          };

          icons = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Install and use the matching WhiteSur icon theme.  Disable to
              keep the Catppuccin Papirus icons.
            '';
          };

          cursors = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Install and use the WhiteSur cursor theme.  Disable to keep
              the Catppuccin cursors.
            '';
          };
        };
      };
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

    # Resolved theme names, consumed by the individual desktop profiles.
    gtkThemeName = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = gtkThemeName;
      description = "Resolved GTK theme name (internal).";
    };

    iconThemeName = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = iconThemeName;
      description = "Resolved icon theme name (internal).";
    };

    cursorThemeName = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = cursorName;
      description = "Resolved cursor theme name (internal).";
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

    environment.systemPackages = themePackages ++ (with pkgs; [
      # Theme assets
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
    ]) ++ lib.optionals
      (cfg.enableDisplayManager && cfg.profile != "xfce")
      [ catppuccinSddm ];

    environment.sessionVariables = {
      GTK_THEME = gtkThemeName;
      XCURSOR_THEME = cursorName;
      XCURSOR_SIZE = "24";
    };

    environment.etc."gtk-2.0/gtkrc".text = ''
      gtk-theme-name = "${gtkThemeName}"
      gtk-icon-theme-name = "${iconThemeName}"
      gtk-font-name = "Inter 10"
      gtk-cursor-theme-name = "${cursorName}"
      gtk-cursor-theme-size = 24
    '';

    environment.etc."gtk-3.0/settings.ini".text = ''
      [Settings]
      gtk-theme-name=${gtkThemeName}
      gtk-icon-theme-name=${iconThemeName}
      gtk-font-name=Inter 10
      gtk-cursor-theme-name=${cursorName}
      gtk-cursor-theme-size=24
      gtk-application-prefer-dark-theme=${lib.boolToString preferDarkTheme}
      gtk-enable-animations=true
    '';

    environment.etc."gtk-4.0/settings.ini".text = ''
      [Settings]
      gtk-theme-name=${gtkThemeName}
      gtk-icon-theme-name=${iconThemeName}
      gtk-font-name=Inter 10
      gtk-cursor-theme-name=${cursorName}
      gtk-cursor-theme-size=24
      gtk-application-prefer-dark-theme=${lib.boolToString preferDarkTheme}
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
      icon_theme=${iconThemeName}
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
        # NixOS 25.05 defaults to the Qt5 SDDM; the Catppuccin theme is Qt6.
        package = pkgs.kdePackages.sddm;
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
        extraPackages = with pkgs.kdePackages; [ qtsvg ];
      };
  };
}
