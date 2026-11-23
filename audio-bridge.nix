# Audio side of the Mac bridge: stream everything NixOS plays to the Mac, so
# the AirPods connected to the Mac can play it.
#
# A PipeWire null sink ("AirPods-Bridge") becomes the default output. A
# socket-activated service captures its monitor and writes raw PCM (48 kHz,
# 16 bit, stereo) to the TCP connection; the Mac pipes that into `sox`/`play`.
#
# A plain PCM socket is used instead of Snapcast on purpose: snapclient 0.35's
# CoreAudio player closes immediately after start (uninitialized timer) and its
# file player replays stale buffers as white noise when a chunk is late.
{ config, lib, pkgs, ... }:

let
  user = "nixos";
  # The NixOS normal user is created with UID 1000 by activation;
  # `users.users.nixos.uid` is null unless it is set explicitly.
  uid = let configured = config.users.users.${user}.uid; in
    if configured != null then configured else 1000;
  runtimeDir = "/run/user/${toString uid}";
  pulse = pkgs.pulseaudio;
  sink = "airpods_bridge";
  port = 4953;

  # Switches the default output between the bridge and the local hardware sink.
  audioAirpods = pkgs.writeShellScriptBin "audio-airpods" ''
    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-${runtimeDir}}"
    if ! ${pulse}/bin/pactl list short sinks | awk '{ print $2 }' | grep -qx ${sink}; then
      ${pulse}/bin/pactl load-module module-null-sink sink_name=${sink} \
        sink_properties=device.description=AirPods-Bridge >/dev/null
    fi
    exec ${pulse}/bin/pactl set-default-sink ${sink}
  '';

  audioLocal = pkgs.writeShellScriptBin "audio-local" ''
    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-${runtimeDir}}"
    local_sink=$(${pulse}/bin/pactl list short sinks |
      awk -v bridge=${sink} '$2 != bridge { print $2; exit }')
    if [ -z "$local_sink" ]; then
      echo "No local audio sink found." >&2
      exit 1
    fi
    exec ${pulse}/bin/pactl set-default-sink "$local_sink"
  '';

  # Runs once per accepted TCP connection; stdout is the socket.
  serveConnection = pkgs.writeShellScript "airpods-audio-connection" ''
    set -u

    # Wait for the per-user PipeWire/PulseAudio socket.
    for _ in $(seq 1 60); do
      [ -S "${runtimeDir}/pulse/native" ] && break
      sleep 1
    done

    if ! ${pulse}/bin/pactl list short sinks | awk '{ print $2 }' | grep -qx ${sink}; then
      ${pulse}/bin/pactl load-module module-null-sink sink_name=${sink} \
        sink_properties=device.description=AirPods-Bridge >/dev/null 2>&1 || true
    fi

    ${pulse}/bin/pactl set-default-sink ${sink} >/dev/null 2>&1 || true

    exec ${pulse}/bin/parec --device=${sink}.monitor \
      --format=s16le --rate=48000 --channels=2 --latency-msec=20
  '';
in
{
  systemd.sockets.airpods-audio = {
    description = "AirPods audio bridge (raw PCM over TCP)";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "192.168.178.5:${toString port}" ];
    socketConfig.Accept = true;
  };

  systemd.services."airpods-audio@" = {
    description = "AirPods audio bridge connection";
    serviceConfig = {
      User = user;
      Group = "users";
      StandardInput = "socket";
      StandardOutput = "socket";
      Environment = [
        "XDG_RUNTIME_DIR=${runtimeDir}"
        "PULSE_SERVER=unix:${runtimeDir}/pulse/native"
      ];
    };
    script = "exec ${serveConnection}";
  };

  # Bound to the LAN address, so the stream is not reachable from the
  # Tailscale or container interfaces.
  networking.firewall.allowedTCPPorts = [ port ];

  environment.systemPackages = [ pulse audioAirpods audioLocal ];
}