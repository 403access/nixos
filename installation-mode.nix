# Selected by install/install.sh.
#
# The repository default is a plain NixOS install.  The installer overwrites
# this file on the target system with one of:
#
#   myInstall.mode = "nixos";  # NixOS only
#   myInstall.mode = "vm";     # NixOS + a Windows 11 VM
#   myInstall.mode = "dual";   # NixOS + Windows dual boot
#
# Keeping this in its own file means `nixos-rebuild switch` keeps working after
# the installer has run, and the choice is visible in the configuration.
{ ... }:

{
  myInstall.mode = "nixos";
}
