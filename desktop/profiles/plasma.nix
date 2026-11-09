{ config, lib, pkgs, ... }:

let
  cfg = config.myDesktop;

  capitalise = value:
    lib.toUpper (builtins.substring 0 1 value)
    + builtins.substring 1 (-1) value;

  flavour = capitalise cfg.flavour;
  accent = capitalise cfg.accent;
  colorScheme = "Catppuccin${flavour}${accent}";
  lookAndFeel = "Catppuccin-${flavour}-${accent}";
  auroraeTheme = "Catppuccin${flavour}-Modern";

  catppuccinKde = pkgs.catppuccin-kde.override {
    flavour = [ cfg.flavour ];
    accents = [ cfg.accent ];
    winDecStyles = [ "modern" ];
  };

  # KDE's apply helpers live in plasma-workspace.  Run them shortly after
  # plasmashell starts so a fresh account gets the full Catppuccin look.
  themeScript = pkgs.writeShellScript "plasma-catppuccin-theme" ''
    # Wait for plasmashell before applying live settings.  The kdeglobals
    # defaults still apply even if this helper runs too early.
    for _ in $(seq 1 30); do
      pgrep -x plasmashell >/dev/null && break
      sleep 1
    done
    sleep 2
    ${pkgs.kdePackages.plasma-workspace}/bin/plasma-apply-colorscheme ${colorScheme} || true
    ${pkgs.kdePackages.plasma-workspace}/bin/plasma-apply-desktoptheme default || true
    ${pkgs.kdePackages.plasma-workspace}/bin/plasma-apply-wallpaperimage ${cfg.wallpaper} || true
  '';

in
lib.mkIf (cfg.enable && cfg.profile == "plasma") {
  services.xserver.enable = true;
  services.desktopManager.plasma6.enable = true;

  services.displayManager.defaultSession = "plasma";
  services.xrdp.defaultWindowManager = "startplasma-x11";
  programs.kdeconnect.enable = true;

  environment.systemPackages = with pkgs;
    [
      catppuccinKde
    ]
    ++ (with pkgs.kdePackages; [
      dolphin
      konsole
      kate
      ark
      gwenview
      spectacle
      kcalc
      discover
      partitionmanager
      kdeconnect-kde
      plasma-browser-integration
      plasma-nm
      plasma-pa
      bluedevil
      powerdevil
      kscreen
      sddm-kcm
      breeze-gtk
      qtwayland
    ]);

  # System-wide KDE defaults.  Per-user changes still win.
  environment.etc."xdg/kdeglobals".text = ''
    [General]
    ColorScheme=${colorScheme}
    LookAndFeelPackage=${lookAndFeel}
    font=Inter,11,-1,5,50,0,0,0,0,0
    menuFont=Inter,11,-1,5,50,0,0,0,0,0
    toolBarFont=Inter,11,-1,5,50,0,0,0,0,0
    smallestReadableFont=Inter,9,-1,5,50,0,0,0,0,0
    [Icons]
    Theme=${cfg.iconThemeName}
    [KDE]
    SingleClick=false
  '';

  environment.etc."xdg/kwinrc".text = ''
    [org.kde.kdecoration2]
    library=org.kde.kwin.aurorae
    theme=__aurorae__svg__${auroraeTheme}
  '';

  environment.etc."xdg/autostart/00-nixos-control-theme.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=NixOS Control theme
    Comment=Apply the Catppuccin colour scheme and wallpaper
    Exec=${themeScript}
    OnlyShowIn=KDE;
    NoDisplay=true
    X-KDE-autostart-after=panel
  '';

  myDesktop.sessionCommand =
    "${pkgs.dbus}/bin/dbus-run-session ${pkgs.kdePackages.plasma-workspace}/bin/startplasma-x11";
  myDesktop.sessionType = "x11";
  myDesktop.supportedOverVnc = true;
}
