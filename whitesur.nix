# Host-local WhiteSur module.
#
# This is the file used on the actual machine as /etc/nixos/whitesur.nix.  It
# is imported by a base configuration that does not already import the desktop
# module.  The full `configuration.nix` in this repository has the same
# settings inline, so this module is only needed when applying WhiteSur to an
# older or separate base configuration.
#
# The desktop module keeps the existing XFCE session; WhiteSur replaces GTK
# applications, icons, cursors and the Plank dock.  Set gtkTheme = "catppuccin"
# to revert to the previous look.
{ ... }:

{
  imports = [ ./desktop ];

  myDesktop = {
    enable = true;
    profile = "xfce";
    user = "nixos";

    gtkTheme = "whitesur";
    whiteSur = {
      variant = "dark";
      accent = "blue";
      icons = true;
      cursors = true;
      plank = true;
    };
  };
}
