{ lib
, stdenv
, nodejs
, makeWrapper
, bash
, coreutils
, findutils
, gnugrep
, gnused
, util-linux
, kmod
, chntpw
, openssh
, gnutar
, gzip
, qemu
, ntfs3g
, hivex
, libvirt
, nix
, nixos-rebuild ? null
}:

stdenv.mkDerivation {
  pname = "image-studio";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/image-studio $out/bin
    cp -r package.json src web test bin $out/lib/image-studio/
    chmod +x $out/lib/image-studio/bin/image-studio.js $out/lib/image-studio/src/mcp.js

    runtimePath=${lib.makeBinPath (lib.filter (p: p != null) [
      bash coreutils findutils gnugrep gnused util-linux kmod chntpw
      openssh gnutar gzip qemu ntfs3g hivex libvirt nix nixos-rebuild
    ])}

    makeWrapper ${nodejs}/bin/node $out/bin/image-studio \
      --add-flags "$out/lib/image-studio/bin/image-studio.js" \
      --prefix PATH : "$runtimePath"

    makeWrapper ${nodejs}/bin/node $out/bin/image-studio-mcp \
      --add-flags "$out/lib/image-studio/src/mcp.js" \
      --prefix PATH : "$runtimePath"

    runHook postInstall
  '';

  meta = with lib; {
    description = "MCP server and web UI for building and editing NixOS and Windows images";
    homepage = "https://github.com/403access/nixos";
    license = licenses.mit;
    mainProgram = "image-studio";
    platforms = platforms.linux;
  };
}