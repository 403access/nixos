# Jottacloud CLI moves faster than the nixpkgs 25.05 package.  Pin the current
# upstream Linux binary here until the channel catches up.
{ pkgs, ... }:

{
  nixpkgs.overlays = [
    (final: prev: {
      jotta-cli = prev.jotta-cli.overrideAttrs (old: {
        version = "0.17.176206";
        src = prev.fetchzip {
          url = "https://repo.jotta.us/archives/linux/amd64/jotta-cli-0.17.176206_linux_amd64.tar.gz";
          hash = "sha256-fVn1MpjwVUyjTF/oVnmx4AOgIfEfdK+G1ikMO1ZypoE=";
          stripRoot = false;
        };
      });
    })
  ];
}
