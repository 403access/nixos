{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  packages = with pkgs; [
    # WIM inspection, apply/capture and solid compression.
    wimlib
    # ISO extraction and repacking. libisoburn provides the xorriso binary.
    p7zip
    libisoburn
    # Registry hives, filesystems and scripting helpers for advanced edits.
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

  shellHook = ''
    echo "Windows 11 slim-image toolchain"
    echo "  wimlib-imagex, 7z, xorriso, python3, hivex, chntpw"
    echo "  Build: ./build-win11.sh --iso /path/to/Win11.iso --profile lean"
  '';
}
