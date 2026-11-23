# Ungoogled Chromium from the upstream portable Linux AppImage.
#
# nixpkgs' `ungoogled-chromium` is a source build and is not available from
# cache.nixos.org (the narinfo returns 404), so enabling it starts a multi-hour
# Chromium compile. The upstream project publishes a self-contained AppImage;
# this module extracts and wraps it, so the browser installs from a download.
{ pkgs, lib, ... }:

let
  pname = "ungoogled-chromium";
  version = "156.0.8078.79";

  src = pkgs.fetchurl {
    url = "https://github.com/ungoogled-software/ungoogled-chromium-portablelinux/releases/download/${version}-1/${pname}-${version}-1-x86_64.AppImage";
    sha256 = "1rs6zigwna483bqchsynmpcjq2066zkfb9v0x84xls7x9dnv6f30";
  };

  appimageContents = pkgs.appimageTools.extract { inherit pname version src; };

  desktopItem = pkgs.makeDesktopItem {
    name = pname;
    desktopName = "Ungoogled Chromium";
    exec = "${pname} %U";
    icon = pname;
    categories = [ "Network" "WebBrowser" ];
    mimeTypes = [
      "text/html"
      "x-scheme-handler/http"
      "x-scheme-handler/https"
    ];
  };

  ungoogled-chromium = pkgs.appimageTools.wrapType2 {
    inherit pname version src;

    extraInstallCommands = ''
      if [ -f ${appimageContents}/${pname}.png ]; then
        install -Dm644 ${appimageContents}/${pname}.png \
          $out/share/icons/hicolor/256x256/apps/${pname}.png
      fi
      mkdir -p $out/share/applications
      install -m644 ${desktopItem}/share/applications/* \
        $out/share/applications/
    '';

    meta = {
      description = "Chromium without Google integration (upstream portable build)";
      homepage = "https://github.com/ungoogled-software/ungoogled-chromium-portablelinux";
      license = lib.licenses.bsd3;
      platforms = [ "x86_64-linux" ];
      sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
      mainProgram = pname;
    };
  };
in
{
  environment.systemPackages = [ ungoogled-chromium ];
}