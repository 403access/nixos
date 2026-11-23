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

         2. virt-manager       Manage the Windows 11 VM, once the desktop is up
                               (or click the Virtual Machine Manager icon).

         3. bridge-status      Show whether the Mac keyboard/mouse bridge is
                               connected.

         4. nixos-control      Show the web dashboard URL and the control
                               service state.

         5. stop-desktop       Stop the desktop and return to this console.

         6. reboot / poweroff  Restart or shut down the machine.

         7. console-help       Print this message again.

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
    consoleShell
    startDesktop
    stopDesktop
    bridgeStatus
    controlInfo
    consoleHelp
  ];

  # Shown after login on the text consoles, and by the console terminal.
  environment.etc."motd".text = helpText;
  services.getty.helpLine = "Desktop is not running. Log in as ${user} and run 'start-desktop', or read the help after login.";
}