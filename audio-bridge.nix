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

  # Switches the default output between the bridge and the local hardware
  # sink, and reports whether audio is currently bridged.
  audioBridge = pkgs.writeShellScriptBin "audio-bridge" ''
    set -u
    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-${runtimeDir}}"
    export PULSE_SERVER="''${PULSE_SERVER:-unix:${runtimeDir}/pulse/native}"
    bridge=${sink}
    ctl=${pulse}/bin/pactl

    ensure_sink() {
      if ! "$ctl" list short sinks | awk '{ print $2 }' | grep -qx "$bridge"; then
        "$ctl" load-module module-null-sink sink_name="$bridge" \
          sink_properties=device.description=AirPods-Bridge >/dev/null
      fi
    }

    local_sink() {
      "$ctl" list short sinks | awk -v b="$bridge" '$2 != b { print $2; exit }'
    }

    case "''${1:-status}" in
      on)
        ensure_sink
        "$ctl" set-default-sink "$bridge"
        echo "Audio bridge: ON. NixOS audio now plays on the Mac (AirPods)."
        ;;
      off)
        target=$(local_sink)
        if [ -z "$target" ]; then
          echo "No local audio sink found." >&2
          exit 1
        fi
        "$ctl" set-default-sink "$target"
        echo "Audio bridge: OFF. NixOS audio plays on $target."
        ;;
      status)
        current=$("$ctl" get-default-sink)
        if [ "$current" = "$bridge" ]; then
          echo "audio bridge: ON  (default sink: $bridge)"
        else
          echo "audio bridge: OFF (default sink: $current)"
        fi
        if "$ctl" list short sinks | awk '{ print $2 }' | grep -qx "$bridge"; then
          echo "bridge sink:   present"
        else
          echo "bridge sink:   not created"
        fi
        conns=$(ss -Htn state established "( sport = :${toString port} )" 2>/dev/null | wc -l)
        echo "mac client:    ''${conns} connection(s) on port ${toString port}"
        ;;
      *)
        echo "usage: audio-bridge [on|off|status]" >&2
        exit 2
        ;;
    esac
  '';

  audioAirpods = pkgs.writeShellScriptBin "audio-airpods" ''
    exec ${audioBridge}/bin/audio-bridge on
  '';

  audioLocal = pkgs.writeShellScriptBin "audio-local" ''
    exec ${audioBridge}/bin/audio-bridge off
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

  environment.systemPackages = [ pulse audioBridge audioAirpods audioLocal ];
}