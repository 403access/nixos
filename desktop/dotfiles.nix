# Copy a directory of theme files into a writable derivation and substitute
# host-specific values.  Used to link declarative dotfiles into a user's home.
{ pkgs, lib }:

name: src: substitutions:
pkgs.runCommand "${name}-dotfiles" { } ''
  mkdir -p "$out"
  cp -r --no-preserve=mode ${src}/. "$out/"
  chmod -R u+w "$out"
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList
    (file: value: ''
      substituteInPlace "$out/${file}" \
        --replace-fail ${lib.escapeShellArg value.from} ${lib.escapeShellArg value.to}
    '')
    substitutions)}
''
