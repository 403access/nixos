# Boot into a full-screen terminal instead of the desktop.
#
# The terminal runs on a minimal X display (openbox + xfce4-terminal, no
# desktop session), because the InputLeap client can only inject into X.
# That keeps the Mac keyboard and mouse bridge available from boot, while
# `start-desktop` starts XFCE on the same display only when it is wanted.
#
# SSH is untouched: sshd keeps running at all times, and it is also possible
# to start the desktop from the Mac (`ssh nixos@192.168.178.5 start-desktop`).
{ config, pkgs, lib, ... }:

let
  user = "nixos";

  helpText = ''
       NixOS console
       =============

       The desktop is not running. This terminal runs on a minimal X display,
       which keeps the Mac keyboard and mouse bridge (InputLeap) available.

       Suggested order:

         1. start-desktop      Start the XFCE desktop on this display.
                               The full-screen terminal closes and the desktop
                               appears. Log out of XFCE to come back here.

         2. start-vm           Show the Windows 11 VM in a window on this
                               display, without starting the desktop.
                               Alt+Tab switches back to this terminal.

            start-vm-rdp       Optional alternative: open the Windows console
                               session over RDP (fullscreen, client-side cursor,
                               AVC444). Needs the Windows password; start-vm
                               (SPICE) stays available. `start-vm-rdp --legacy`
                               disables AVC444. Keep the Mac on the nixos
                               screen (Ctrl+Option+1) for input.

         3. virt-manager       Manage the Windows 11 VM, once the desktop is up
                               (or click the Virtual Machine Manager icon).

         4. bridge-status      Show whether the Mac keyboard/mouse bridge is
                               connected.

         5. nixos-control      Show the web dashboard URL and the control
                               service state.

         6. audio-bridge       Show whether NixOS audio is bridged to the
                               AirPods. `audio-bridge on` / `audio-bridge off`
                               switches it; audio-airpods / audio-local are
                               shortcuts for on / off.

         7. vm-audio-usb       Optional low-latency FL Studio path: attach the
                               USB audio codec to the Windows VM
                               (`on` / `off` / `status`). The host's local
                               audio pauses while it is attached.

         8. vm-audio-profile   Optional audio CPU profile: 4 vCPUs pinned to
                               host CPUs 4-7 (`on --yes` / `off --yes` /
                               `status`). Restarts the VM; `--dry-run` only
                               writes the XML.

         9. stop-desktop       Stop the desktop and return to this console.

        10. reboot / poweroff  Restart or shut down the machine.

        11. console-help       Print this message again.

       Other access:
         - SSH is always available:  ssh nixos@192.168.178.5
         - Plain text consoles without the Mac bridge: Ctrl+Alt+F2 .. F6
         - start-desktop also works from the Mac:
             ssh nixos@192.168.178.5 start-desktop
         - Documentation: /etc/nixos/docs/apple-keyboard.md
  '';

  # Prints the help, then hands over to the user's login shell.
  consoleShell = pkgs.writeShellScriptBin "console-shell" ''
    cat /etc/motd
    exec "''${SHELL:-/bin/bash}" -l
  '';

  startDesktop = pkgs.writeShellScriptBin "start-desktop" ''
    set -u
    run_dir="''${XDG_RUNTIME_DIR:-/tmp}"
    pidfile="$run_dir/nixos-desktop.pid"

    if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      echo "The XFCE desktop is already running."
      exit 0
    fi

    # Allow starting the desktop over SSH as well.
    if [ -z "''${DISPLAY:-}" ]; then
      export DISPLAY=:0
      export XAUTHORITY="$HOME/.Xauthority"
    fi

    # The console session runs openbox; XFCE starts its own window manager.
    if [ -f "$run_dir/nixos-console-wm.pid" ]; then
      kill "$(cat "$run_dir/nixos-console-wm.pid")" 2>/dev/null || true
      rm -f "$run_dir/nixos-console-wm.pid"
      sleep 1
    fi

    echo "Starting the XFCE desktop..."

    XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_DESKTOP=xfce DESKTOP_SESSION=xfce \
      setsid ${pkgs.xfce.xfce4-session}/bin/xfce4-session \
      >"$run_dir/nixos-desktop.log" 2>&1 &
    desktop_pid=$!
    printf '%s\n' "$desktop_pid" > "$pidfile"
    sleep 3

    if ! kill -0 "$desktop_pid" 2>/dev/null; then
      echo "The desktop failed to start. See $run_dir/nixos-desktop.log" >&2
      rm -f "$pidfile"
      ${pkgs.openbox}/bin/openbox >/dev/null 2>&1 &
      printf '%s\n' "$!" > "$run_dir/nixos-console-wm.pid"
      exit 1
    fi

    echo "Desktop started. Log out of XFCE to return to this console."

    # The full-screen console terminal would hide the desktop; close it.
    if [ -f "$run_dir/nixos-console-term.pid" ]; then
      kill "$(cat "$run_dir/nixos-console-term.pid")" 2>/dev/null || true
      rm -f "$run_dir/nixos-console-term.pid"
    fi
  '';

  stopDesktop = pkgs.writeShellScriptBin "stop-desktop" ''
    set -u
    run_dir="''${XDG_RUNTIME_DIR:-/tmp}"
    pidfile="$run_dir/nixos-desktop.pid"

    if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      kill "$(cat "$pidfile")" 2>/dev/null || true
      rm -f "$pidfile"
      echo "Desktop stopped; the console will reappear."
    else
      echo "The desktop is not running."
    fi
  '';

  startVm = pkgs.writeShellScriptBin "start-vm" ''
    set -u
    domain="win11-stock"

    # Allow starting the viewer over SSH as well.
    if [ -z "''${DISPLAY:-}" ]; then
      export DISPLAY=:0
      export XAUTHORITY="$HOME/.Xauthority"
    fi

    run_dir="''${XDG_RUNTIME_DIR:-/tmp}"
    pidfile="$run_dir/nixos-vm-viewer.pid"

    if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      echo "The Windows 11 viewer is already open."
      exit 0
    fi

    state=$(virsh -c qemu:///system domstate "$domain" 2>/dev/null | head -n 1)
    if [ "$state" != "running" ]; then
      echo "Starting $domain..."
      virsh -c qemu:///system start "$domain" >/dev/null || {
        echo "Could not start $domain." >&2
        exit 1
      }
      sleep 3
    fi

    echo "Opening the Windows 11 display (Alt+Tab returns to this terminal)..."
    setsid ${pkgs.virt-viewer}/bin/virt-viewer \
      --connect qemu:///system --wait --full-screen --auto-resize=always "$domain" \
      >"$run_dir/nixos-vm-viewer.log" 2>&1 &
    printf '%s\n' "$!" > "$pidfile"
  '';

  startVmRdp = pkgs.writeShellScriptBin "start-vm-rdp" ''
    set -u
    domain="win11-stock"
    legacy=0
    if [ "''${1:-}" = "--legacy" ]; then
      legacy=1
    fi

    # Allow starting the session over SSH as well.
    if [ -z "''${DISPLAY:-}" ]; then
      export DISPLAY=:0
      export XAUTHORITY="$HOME/.Xauthority"
    fi

    state=$(virsh -c qemu:///system domstate "$domain" 2>/dev/null | head -n 1)
    if [ "$state" != "running" ]; then
      echo "Starting $domain..."
      virsh -c qemu:///system start "$domain" >/dev/null || {
        echo "Could not start $domain." >&2
        exit 1
      }
      sleep 3
    fi

    ip=$(virsh -c qemu:///system domifaddr "$domain" --source lease 2>/dev/null |
      awk '/ipv4/ { print $4; exit }' | cut -d/ -f1)
    if [ -z "$ip" ]; then
      echo "Could not determine the Windows VM address." >&2
      exit 1
    fi

    if ! timeout 3 bash -c "echo > /dev/tcp/$ip/3389" 2>/dev/null; then
      echo "RDP is not reachable on $ip:3389 — enable it inside Windows first." >&2
      exit 1
    fi

    echo "Opening the Windows console session over RDP (fullscreen)..."
    echo "Keep the Mac on the nixos screen (Ctrl+Option+1) for input, not Windows-VM."

    if [ "$legacy" = 1 ]; then
      echo "Codec: legacy (no AVC444)."
      exec ${pkgs.freerdp}/bin/xfreerdp \
        /v:"$ip":3389 \
        /u:Windows-PC /d:Windows-VM \
        +admin +dynamic-resolution /f \
        /cert:ignore /sound /clipboard +auto-reconnect
    fi

    echo "Codec: AVC444, network: lan."
    exec ${pkgs.freerdp}/bin/xfreerdp \
      /v:"$ip":3389 \
      /u:Windows-PC /d:Windows-VM \
      +admin +dynamic-resolution /f \
      /gfx:AVC444:on /network:lan \
      /cert:ignore /sound /clipboard +auto-reconnect
  '';

  vmAudioUsb = pkgs.writeShellScriptBin "vm-audio-usb" ''
    set -u
    domain="win11-stock"
    xml="/tmp/win11-audio-codec.xml"

    cat > "$xml" <<'XML'
<hostdev mode="subsystem" type="usb" managed="yes">
  <source>
    <vendor id="0x08bb"/>
    <product id="0x2902"/>
  </source>
</hostdev>
XML

    case "''${1:-status}" in
      on)
        virsh -c qemu:///system attach-device "$domain" "$xml" --live || exit 1
        echo "USB audio codec attached to the Windows VM."
        echo "Select 'USB Audio CODEC' (or ASIO4ALL over it) in FL Studio."
        ;;
      off)
        virsh -c qemu:///system detach-device "$domain" "$xml" --live || exit 1
        echo "USB audio codec returned to the host."
        ;;
      status)
        if virsh -c qemu:///system dumpxml "$domain" | grep -q "08bb"; then
          echo "USB audio codec: attached to the Windows VM"
        else
          echo "USB audio codec: on the host"
        fi
        ;;
      *)
        echo "usage: vm-audio-usb [on|off|status]" >&2
        exit 2
        ;;
    esac
  '';

  vmAudioProfile = pkgs.writeShellScriptBin "vm-audio-profile" ''
    set -u
    domain="win11-stock"
    state_dir="$HOME/.local/share/nixos-vm"
    desktop_xml="$state_dir/win11-stock-desktop.xml"
    audio_xml="$state_dir/win11-stock-audio.xml"
    py=${pkgs.python3}/bin/python3

    mkdir -p "$state_dir"

    mode="''${1:-status}"
    yes=0
    dry=0
    shift || true
    for arg in "$@"; do
      case "$arg" in
        --yes) yes=1 ;;
        --dry-run) dry=1 ;;
      esac
    done

    is_audio() {
      local xml
      xml=$(virsh -c qemu:///system dumpxml --inactive "$domain" 2>/dev/null) || return 1
      printf '%s\n' "$xml" | grep -q "<vcpu[^>]*>4</vcpu>" &&
        printf '%s\n' "$xml" | grep -q "vcpupin"
    }

    stop_vm() {
      [ "$(virsh -c qemu:///system domstate "$domain" 2>/dev/null)" = "running" ] || return 0
      if [ "$yes" != 1 ]; then
        echo "This restarts Windows. Re-run with --yes to continue." >&2
        return 1
      fi
      echo "Shutting down $domain (ACPI)..."
      virsh -c qemu:///system shutdown "$domain" >/dev/null || return 1
      for _ in $(seq 1 90); do
        [ "$(virsh -c qemu:///system domstate "$domain" 2>/dev/null)" = "shut off" ] && return 0
        sleep 2
      done
      echo "Windows did not shut down; profile not changed." >&2
      return 1
    }

    make_audio() {
      "$py" - "$1" "$2" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
s = re.sub(r"<vcpu[^>]*>8</vcpu>", "<vcpu placement='static'>4</vcpu>", s, count=1)
s = re.sub(r"(<topology[^>]*threads=')2(')", r"\g<1>1\g<2>", s, count=1)
tune = """  <cputune>
    <vcpupin vcpu='0' cpuset='4'/>
    <vcpupin vcpu='1' cpuset='5'/>
    <vcpupin vcpu='2' cpuset='6'/>
    <vcpupin vcpu='3' cpuset='7'/>
    <emulatorpin cpuset='3'/>
    <shares>512</shares>
  </cputune>
"""
if "<cputune>" in s:
    s = re.sub(r"  <cputune>.*?</cputune>\n", tune, s, count=1, flags=re.S)
else:
    s = s.replace("  <os>", tune + "  <os>", 1)
open(dst, "w").write(s)
PY
    }

    restore_desktop() {
      if [ -f "$desktop_xml" ]; then
        cp "$desktop_xml" "$1"
        return
      fi
      virsh -c qemu:///system dumpxml --inactive "$domain" > /tmp/win11-current.xml
      "$py" - /tmp/win11-current.xml "$1" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
s = re.sub(r"<vcpu[^>]*>4</vcpu>", "<vcpu placement='static'>8</vcpu>", s, count=1)
s = re.sub(r"(<topology[^>]*threads=')1(')", r"\g<1>2\g<2>", s, count=1)
s = re.sub(
    r"  <cputune>.*?</cputune>\n",
    "  <cputune>\n    <shares>256</shares>\n  </cputune>\n",
    s,
    count=1,
    flags=re.S,
)
open(dst, "w").write(s)
PY
    }

    case "$mode" in
      on)
        if is_audio; then
          echo "Audio CPU profile is already active."
          exit 0
        fi
        if [ "$dry" = 1 ]; then
          virsh -c qemu:///system dumpxml --inactive "$domain" > "$desktop_xml"
          make_audio "$desktop_xml" "$audio_xml"
          echo "Dry run: wrote $audio_xml (not applied)."
          exit 0
        fi
        stop_vm || exit 1
        virsh -c qemu:///system dumpxml --inactive "$domain" > "$desktop_xml"
        make_audio "$desktop_xml" "$audio_xml"
        virsh -c qemu:///system define "$audio_xml" >/dev/null || exit 1
        virsh -c qemu:///system start "$domain" >/dev/null || exit 1
        echo "Audio CPU profile active: 4 vCPUs pinned to host CPUs 4-7."
        echo "Reopen the viewer with start-vm or start-vm-rdp."
        ;;
      off)
        if ! is_audio; then
          echo "Desktop CPU profile is already active."
          exit 0
        fi
        restore_desktop /tmp/win11-desktop.xml
        if [ "$dry" = 1 ]; then
          echo "Dry run: wrote /tmp/win11-desktop.xml (not applied)."
          exit 0
        fi
        stop_vm || exit 1
        virsh -c qemu:///system define /tmp/win11-desktop.xml >/dev/null || exit 1
        virsh -c qemu:///system start "$domain" >/dev/null || exit 1
        echo "Desktop CPU profile active: 8 vCPUs, no pinning."
        echo "Reopen the viewer with start-vm or start-vm-rdp."
        ;;
      status)
        if is_audio; then
          echo "CPU profile: audio (4 vCPUs pinned to host CPUs 4-7)"
        else
          echo "CPU profile: desktop (8 vCPUs, unpinned)"
        fi
        ;;
      *)
        echo "usage: vm-audio-profile [on|off|status] [--yes] [--dry-run]" >&2
        exit 2
        ;;
    esac
  '';

  bridgeStatus = pkgs.writeShellScriptBin "bridge-status" ''
    set -u
    echo "Mac keyboard/mouse bridge (InputLeap client):"
    systemctl --no-pager --lines=0 status input-leap-client || true
  '';

  controlInfo = pkgs.writeShellScriptBin "nixos-control" ''
    set -u
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null |
      awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')
    echo "Web dashboard: http://''${ip:-192.168.178.5}:3050"
    echo
    systemctl --no-pager --lines=0 status nixos-control-web || true
  '';

  consoleHelp = pkgs.writeShellScriptBin "console-help" ''
    cat /etc/motd
  '';
in
{
  # No desktop session at boot: log in automatically into the console session
  # below, which is only a full-screen terminal.
  services.displayManager.defaultSession = lib.mkForce "console";
  services.displayManager.autoLogin = {
    enable = true;
    inherit user;
  };

  services.xserver.displayManager.session = [
    # The legacy session option pairs every desktop with every window
    # manager, so provide an empty window-manager entry as the counterpart.
    {
      manage = "window";
      name = "none";
      start = "";
    }
    {
      manage = "desktop";
      name = "console";
      desktopNames = [ "CONSOLE" ];
      start = ''
        run_dir="''${XDG_RUNTIME_DIR:-/tmp}"

        # A window manager is needed so the terminal can go full-screen.
        ${pkgs.openbox}/bin/openbox &
        printf '%s\n' "$!" > "$run_dir/nixos-console-wm.pid"

        ${pkgs.xfce.xfce4-terminal}/bin/xfce4-terminal \
          --disable-server --fullscreen --hide-menubar \
          --title="NixOS console" \
          --command="${consoleShell}/bin/console-shell" &
        term_pid=$!
        printf '%s\n' "$term_pid" > "$run_dir/nixos-console-term.pid"

        wait "$term_pid"

        # Keep the session alive while a desktop started by start-desktop runs.
        while [ -f "$run_dir/nixos-desktop.pid" ] &&
          kill -0 "$(cat "$run_dir/nixos-desktop.pid")" 2>/dev/null; do
          sleep 2
        done

        rm -f "$run_dir/nixos-console-term.pid" \
              "$run_dir/nixos-console-wm.pid" \
              "$run_dir/nixos-desktop.pid"
      '';
    }
  ];

  environment.systemPackages = [
    pkgs.openbox
    pkgs.xfce.xfce4-terminal
    pkgs.virt-viewer
    pkgs.freerdp
    consoleShell
    startDesktop
    startVm
    startVmRdp
    stopDesktop
    vmAudioUsb
    vmAudioProfile
    bridgeStatus
    controlInfo
    consoleHelp
  ];

  # Shown after login on the text consoles, and by the console terminal.
  environment.etc."motd".text = helpText;
  services.getty.helpLine = "Desktop is not running. Log in as ${user} and run 'start-desktop', or read the help after login.";
}