# Apple keyboard on the NixOS host

Host: ASUS **PRIME Z270-A** desktop, NixOS 25.05. Updated **2026-11-23**.

## Current hardware finding

The host has **no Bluetooth radio**:

- `/sys/class/bluetooth` was empty; no `hci0`.
- No Bluetooth USB device (only a Logitech USB receiver and a USB audio codec).
- No PCIe wireless/Bluetooth controller.
- `rfkill` reports no Bluetooth device.

### Why not the Logitech receiver?

The receiver is a 2.4 GHz Logitech endpoint, not a Bluetooth adapter. It only
accepts Logitech devices that completed Logitech pairing and hold the receiver's
AES keys. HID++ has pairing commands, but they put the receiver into Logitech
pairing mode; they cannot enroll a standard Bluetooth HID keyboard. An app on
the host cannot bridge the two radios.

If the receiver is a Bolt (BLE radio), replacing its firmware with a BLE HID
host would theoretically work, but that is a firmware project, not an app, and
it would stop the dongle being a Logitech receiver. A USB Bluetooth dongle is
the practical fix.

The receiver can still be inspected with `hidpp-probe`, the web dashboard or the
iOS Peripherals screen; see [`peripherals.md`](peripherals.md) and
[`server/README.md`](../server/README.md#logitech-receiver-probe).

The software stack is now ready, but an Apple **wireless** keyboard cannot pair
until a Bluetooth adapter is added. There are two usable paths:

1. **Wired** — connect the keyboard with its Lightning/USB-C cable (models that
   have a charging port). This needs no Bluetooth hardware.
2. **Wireless** — plug in a Linux-compatible USB Bluetooth dongle.

## Software support applied

In `configuration.nix`:

```nix
boot.kernelModules = [ "zfs" "btusb" "hidp" "hid_apple" ];

hardware.bluetooth = {
  enable = true;
  powerOnBoot = true;
};

# The stock unit is only wanted by the passive bluetooth.target and refuses to
# start when no adapter exists.  Start it at boot and reset the condition so a
# USB dongle is detected when plugged in later.
systemd.services.bluetooth = {
  wantedBy = lib.mkForce [ "multi-user.target" ];
  unitConfig.ConditionPathIsDirectory = lib.mkForce "";
};
```

`bluez` (for `bluetoothctl`/`btmon`) is in `environment.systemPackages`, and the
`nixos` user is in the `bluetooth` group.

Verified state:

```text
bluetooth.service: enabled, active
WantedBy=multi-user.target
ConditionResult=yes
bluetoothctl list -> (empty)
bluetoothctl show -> No default controller available
```

`bluetoothd` now runs without an adapter, so a dongle is picked up on hotplug
instead of leaving the daemon off until the next boot.

## Wired Apple keyboard

For a Magic Keyboard with a Lightning or USB-C port:

1. Connect it to a free USB port with the charging cable.
2. It enumerates as a normal USB HID keyboard; `usbhid` and `hid_apple` handle
   it. No Bluetooth adapter is needed.
3. Verify:

```bash
cat /proc/bus/input/devices | grep -A5 -i -E 'Apple|Keyboard'
ls -l /dev/input/by-id/
lsmod | grep hid_apple
```

Older Apple Wireless Keyboards that use AA batteries have no wired mode.

## Wireless: compatible USB dongle

Use a dongle with a known Linux-friendly controller, for example:

| Chipset | USB ID | Notes |
| --- | --- | --- |
| CSR8510 A10 | `0a12:0001` | Common and cheap; many counterfeits report fake IDs |
| Realtek RTL8761B | `0bda:8771` | Needs `rtl_bt` firmware; redistributable firmware is already enabled |
| Broadcom BCM20702 | `0a5c:21e8` | Well supported, often used in older laptops |

Avoid no-name “Bluetooth 5.0” dongles that do not identify a real controller.
Check after plugging in:

```bash
lsusb
dmesg | tail -30
bluetoothctl list
bluetoothctl show
```

`bluetoothctl list` should print a controller such as `hci0`. `bluetoothctl
show` should report `Powered: yes` because `powerOnBoot` is enabled.

## Bridge from the Mac (RDP)

The host runs xrdp on port 3389. This is the no-hardware path: keep the Apple
keyboard paired to the Mac and type into a NixOS desktop over RDP.

1. On the Mac, open **Windows App** (Microsoft Remote Desktop).
2. Add a PC: `192.168.178.5`, user `nixos`, port `3389`.
3. Connect and enter the NixOS login password.

The Mac's Apple keyboard then types into the NixOS xrdp session. A ready-made
`.rdp` file with these values can be opened in Windows App; if it is not
imported, use **Add PC** with the same values.

This is a separate xrdp desktop, not the physical console. The Mac must stay on,
and the NixOS host must keep xrdp running. For the physical display and seamless
keyboard/mouse sharing, see
[Bridge from the Mac (InputLeap)](#bridge-from-the-mac-inputleap--physical-console)
below, or add a USB Bluetooth dongle.

The Peripherals app will not list the Apple keyboard: it is not on the Logitech
receiver.

## Bridge from the Mac (InputLeap) — physical console

This is the working no-hardware setup. The Apple keyboard stays paired to the
Mac; the Mac forwards its keyboard and mouse to the **physical** NixOS display,
at the lightdm greeter and inside the XFCE session. No RDP or VNC window is
involved: you look at the NixOS monitor and type on the Apple keyboard.

| Part | Value |
| --- | --- |
| Mac (InputLeap server) | `192.168.178.33` |
| Mac screen name | `MacBook-Air-von-Oliver.local` |
| NixOS screen name | `nixos` |
| Layout | NixOS monitor on the **left**, Mac on the right |
| Port | `24800/tcp` |
| NixOS client | `input-leap-client.service` (root, `Restart=always`) |

Deskflow is the upstream successor and NixOS packages `deskflow` 1.21.2, but its
macOS DMG needs an interactive licence screen that cannot be accepted
unattended. InputLeap 3.0.3 has the same protocol, a plain macOS arm64 tarball,
and the same 3.0.3 package on NixOS, so both ends are version-matched.

### Mac side

1. Install the app (Intel Macs use the `macOS-x86_64` asset instead):

   ```bash
   curl -LO https://github.com/input-leap/input-leap/releases/download/v3.0.3/macOS-Apple_Silicon-debug-v3.0.3.tar.gz
   tar -xzf macOS-Apple_Silicon-debug-v3.0.3.tar.gz
   tar -xzf macOS-Apple_Silicon-debug/InputLeap-macOS-Apple_Silicon.tar.gz
   cp -R InputLeap.app /Applications/
   xattr -dr com.apple.quarantine /Applications/InputLeap.app
   # The release bundle is unsigned; ad-hoc sign it so launchd will run it.
   codesign --force --deep --sign - /Applications/InputLeap.app
   open /Applications/InputLeap.app
   ```

2. Grant **System Settings → Privacy & Security → Accessibility** and
   **Input Monitoring** to InputLeap. Without both, the pointer never crosses.

3. Write the screen layout to
   `~/Library/Application Support/InputLeap/input-leap.conf`:

   ```text
   section: screens
       MacBook-Air-von-Oliver.local:
       nixos:
   end

   section: links
       MacBook-Air-von-Oliver.local:
           left = nixos
       nixos:
           right = MacBook-Air-von-Oliver.local
   end

   section: options
       relativeMouseMoves = false
       screenSaverSync = true
       clipboardSharing = true
       clipboardSharingSize = 100000000
   end
   ```

   The server screen name must match `--name` of the running server (the GUI
   uses `<LocalHostName>.local`). The client screen name must match `--name`
   of the NixOS client (`nixos`).

4. In the InputLeap window, Server tab: enable **Use existing configuration**
   and point it at that file, then click **Start**. The window should say
   *InputLeap is running.*

The server's self-signed certificate SHA-256 is pinned on the NixOS side. If
the Mac ever regenerates it, read the new value from the Server tab
(**SSL Fingerprint**) and update `serverFingerprint` in
`input-leap-client.nix`.

### NixOS side

[`input-leap-client.nix`](../input-leap-client.nix) is imported by
`configuration.nix` and runs the client as root, because the greeter's X cookie
`/var/run/lightdm/root/:0` is readable by root only. Before every start it:

- pins the Mac certificate in `/root/.config/InputLeap/SSL/Fingerprints/TrustedServers.txt`;
- merges the greeter and `nixos` X cookies into `/run/input-leap/xauthority`
  and picks whichever reaches `:0`;
- starts `input-leapc --use-x11 --name nixos --display :0`.

`Restart=always` matters: whenever lightdm restarts the X server or the
session, the client exits and reconnects against the fresh cookie, so the
keyboard keeps working without manual steps.

Deploy changes with:

```bash
sudo nixos-rebuild switch
```

### Boot: console first, desktop on demand

[`console-desktop.nix`](../console-desktop.nix) makes the host boot into a
full-screen terminal instead of a desktop session. This matters for the bridge:
InputLeap injects through X only, so a pure Linux text console would leave the
Apple keyboard and mouse dead. The terminal therefore runs on a minimal X
display.

- lightdm autologs into the `console` session (openbox plus a full-screen
  `xfce4-terminal`), so X and the InputLeap client are up seconds after boot.
- The terminal prints `/etc/motd`, which lists the commands below in the order
  they are normally used.
- `start-desktop` starts XFCE on the same display (stopping openbox first,
  because XFCE starts its own window manager) and closes the console terminal.
- Logging out of XFCE, closing the terminal, or running `stop-desktop` ends the
  session; lightdm immediately starts a fresh console session.

| Command | What it does |
| --- | --- |
| `start-desktop` | Start XFCE on the console display; also works over SSH. |
| `start-vm` | Start (if needed) and show the Windows 11 SPICE console in a window; Alt+Tab returns to the terminal. |
| `stop-desktop` | Stop XFCE and return to the console. |
| `virt-manager` | Windows 11 VM manager (needs the desktop, or opens on the console display). |
| `bridge-status` | Show the InputLeap client unit state. |
| `nixos-control` | Print the web dashboard URL and control service state. |
| `console-help` | Print the help again (`/etc/motd`). |
| `reboot`, `poweroff` | Restart or shut down. |

From the Mac, the desktop can also be started remotely:

```bash
ssh nixos@192.168.178.5 start-desktop
```

The Windows 11 VM does not need XFCE. `start-vm` starts the `win11-stock`
domain if necessary and opens its libvirt SPICE console with `virt-viewer` as a
normal window on the console display, so NixOS can stay in terminal mode while
Windows is visible on the monitor. Close the window (or Alt+Tab back and stop
the viewer) to return to the terminal; the VM keeps running.

Text consoles on `Ctrl+Alt+F2` … `F6` stay available. They have no Mac bridge
(InputLeap cannot inject there), so use the Logitech K800 or SSH on them.

Because the console session autologs in, physical access to the machine gives a
logged-in session. SSH is unaffected: `sshd` stays enabled and reachable at all
times, and no boot step depends on the bridge or on the desktop starting.

### Daily use

- Mac → NixOS: move the trackpad pointer off the **left** edge of the Mac
  screen. Type on the Apple keyboard; the characters appear on the NixOS
  monitor.
- NixOS → Mac: push the pointer to the **right** edge of the NixOS screen
  (Logitech mouse), or move the Mac trackpad back to the right.

### Verify

```bash
systemctl status input-leap-client
journalctl -u input-leap-client -n 30 --no-pager
# "connected to server" plus "entering screen" lines mean the bridge works.

lsof -nP -iTCP:24800          # on the Mac: LISTEN and ESTABLISHED
```

### Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Pointer never leaves the Mac | Accessibility or Input Monitoring not granted; toggle them and click **Reload**. |
| `Connection refused` on NixOS | The Mac server is not started, or InputLeap is closed. Click **Start** on the Server tab. |
| `Fingerprint does not match` | The Mac certificate changed; update `serverFingerprint` and rebuild. |
| `X display has unexpectedly disconnected` | Normal at login; the unit restarts itself within ~2 s. |
| Works in the console terminal, not in the desktop | Check the desktop profile is X11 (XFCE). `--use-x11` injects via XTEST and cannot reach native Wayland clients. |
| `ssl certificate doesn't exist` | Harmless: the server runs with `--disable-client-cert-checking`, so the client certificate is optional. |
| `start-desktop` fails and the console comes back | A leftover XFCE session on another display owns the session-manager name; see below. |

### `start-desktop` fails and the console comes back

Symptom: `start-desktop` prints *The desktop failed to start* (or XFCE flashes up
and disappears), and the console terminal returns. The log in
`$XDG_RUNTIME_DIR/nixos-desktop.log` shows `xfce4-session` exiting at once.

Cause: XFCE allows one session per user. A leftover session on another display —
usually a disconnected xrdp session from an earlier day — owns
`org.xfce.SessionManager` on the user's shared D-Bus bus (`/run/user/1000/bus`).
The `xfce4-session` started by `start-desktop` cannot take the name and exits
immediately with status 0, so XFCE never appears.

Find the leftover session:

```bash
loginctl list-sessions

for s in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
  printf 'session %s: ' "$s"
  loginctl show-session "$s" -p Name -p Service -p Display -p Remote -p Type \
    --value | paste -sd' '
done
```

Look for `xrdp-sesman` with `Display=:10` and `Remote=yes`, then end it:

```bash
loginctl terminate-session <id>

pgrep -af xfce4-session   # should print nothing
busctl --user list | grep -i xfce.Session   # should print nothing
```

`start-desktop` works again. In the logs, `/var/log/lightdm/lightdm.log` shows the
session's `xsession-wrapper .../xsession` exiting with return value 0 after about
150 ms, and `journalctl -b | grep xfce4-session` shows only the ordinary startup
warnings (`_NET_NUMBER_OF_DESKTOPS`, `No GPG agent found`).

Prevention:

1. Log out inside an RDP session instead of only closing the window.
2. Configure xrdp to kill disconnected sessions (`KillDisconnected` /
   `DisconnectedTimeLimit` in `sesman.ini`).
3. Disable xrdp (`services.xrdp.enable = false`) now that the physical console
   and the InputLeap bridge are the primary path.

The InputLeap bridge is not affected: `input-leap-client.service` runs in the
system scope and reconnects when the greeter hands the display to the session.

## Audio bridge (AirPods)

The AirPods pair with the Mac, and the host has no Bluetooth radio, so NixOS
audio is streamed to the Mac and played on its current default output (the
AirPods). This is the audio counterpart of the input bridge above.

```text
NixOS: PipeWire null sink `airpods_bridge` (default output)
       -> airpods-audio.socket on 192.168.178.5:4953
       -> per-connection service: parec <sink>.monitor, 48 kHz/16 bit/stereo
       -> raw PCM over TCP
Mac:   nc -> sox `play` -> default CoreAudio device (AirPods)
```

### NixOS side

[`audio-bridge.nix`](../audio-bridge.nix) is imported by `configuration.nix`:

- the connection service creates the null sink `airpods_bridge`, makes it the
  default output, and captures its monitor;
- `airpods-audio.socket` listens on `192.168.178.5:4953` only, so the stream is
  not exposed on the Tailscale or container interfaces;
- the stream is unauthenticated raw PCM, intended for the home LAN.

Control which output is used:

| Command | Effect |
| --- | --- |
| `audio-airpods` | Route NixOS audio to the bridge (the default). |
| `audio-local` | Route it back to the first hardware sink. |

### Mac side

1. Install the player: `brew install sox`.
2. Save this launcher as
   `~/Library/Application Support/nixos-control/audio-bridge.sh`:

   ```sh
   #!/bin/sh
   exec 2>&1
   /usr/bin/tail -f /dev/null | /usr/bin/nc 192.168.178.5 4953 | \
     /opt/homebrew/bin/play -q -t raw -r 48000 -e signed-integer -b 16 -c 2 -
   ```

3. Save this as
   `~/Library/LaunchAgents/com.nixos-control.audio-bridge.plist`:

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>Label</key>
       <string>com.nixos-control.audio-bridge</string>
       <key>ProgramArguments</key>
       <array>
           <string>/bin/sh</string>
           <string>/Users/olivermolnar/Library/Application Support/nixos-control/audio-bridge.sh</string>
       </array>
       <key>RunAtLoad</key>
       <true/>
       <key>KeepAlive</key>
       <true/>
       <key>ThrottleInterval</key>
       <integer>3</integer>
       <key>StandardOutPath</key>
       <string>/Users/olivermolnar/Library/Logs/nixos-audio-bridge.log</string>
       <key>StandardErrorPath</key>
       <string>/Users/olivermolnar/Library/Logs/nixos-audio-bridge.log</string>
   </dict>
   </plist>
   ```

4. Load it:

   ```bash
   launchctl bootstrap gui/$(id -u) \
     "$HOME/Library/LaunchAgents/com.nixos-control.audio-bridge.plist"
   ```

The agent starts at login and restarts automatically. `sox` opens the default
output when it starts, so after the AirPods (re)connect, re-open it:

```bash
launchctl kickstart -k gui/$(id -u)/com.nixos-control.audio-bridge
```

Logs: `~/Library/Logs/nixos-audio-bridge.log`.

### Notes and troubleshooting

- **No sound:** check `pactl get-default-sink` on the host (must be
  `airpods_bridge`), `ss -tln | grep 4953`, and that the launchd job is running
  (`launchctl print gui/$(id -u)/com.nixos-control.audio-bridge`).
- **Sound on the Mac speakers instead of the AirPods:** the agent opened the
  default device before the AirPods connected; run the `kickstart` command.
- **Snapcast was tried first and rejected:** snapclient 0.35's CoreAudio player
  closes immediately after start (uninitialized timer) and its file player
  replays stale buffers as white noise when a chunk is late. The raw PCM socket
  avoids both bugs.
- **Latency:** the TCP/sox buffer plus the AirPods' own Bluetooth latency. Fine
  for media; not suitable for lip-sync with the VM display.
- The VM's audio follows the default sink too, so Windows sound reaches the
  AirPods through the same bridge.

## Pair the Apple keyboard

1. Put the keyboard in pairing mode: hold its power button until the LED starts
   blinking (about 3 seconds on a Magic Keyboard).
2. Run `bluetoothctl` as `nixos` (or `sudo bluetoothctl`):

```text
power on
agent on
default-agent
scan on
```

Wait for a line like:

```text
[NEW] Device 3C:22:FB:AA:BB:CC Magic Keyboard
```

Then:

```text
pair 3C:22:FB:AA:BB:CC
trust 3C:22:FB:AA:BB:CC
connect 3C:22:FB:AA:BB:CC
info 3C:22:FB:AA:BB:CC
scan off
quit
```

If `bluetoothctl` prints a passkey, type it on the Apple keyboard and press
Enter. `info` should show `Paired: yes`, `Trusted: yes`, `Connected: yes`.

Verify the input device:

```bash
cat /proc/bus/input/devices | grep -A5 -i 'Apple'
ls -l /dev/input/by-id/ | grep -i -E 'Apple|Keyboard'
```

### If pairing fails

```text
remove 3C:22:FB:AA:BB:CC
```

Turn the keyboard off and on, put it back into pairing mode, then repeat. If the
keyboard is still paired to a Mac, remove it there first; most Apple keyboards
keep one active host at a time. Some models can switch between paired hosts with
a dedicated device key, otherwise re-pair.

## Apple Fn keys

`hid_apple` controls the top row. `fnmode` values:

| Value | Behaviour |
| --- | --- |
| `0` | Fn keys disabled |
| `1` | Media keys primary, F1–F12 with Fn (Apple default) |
| `2` | F1–F12 primary, media keys with Fn |
| `3` | Auto |

To make F1–F12 primary permanently:

```nix
boot.extraModprobeConfig = ''
  options hid_apple fnmode=2
'';
```

Then `sudo nixos-rebuild switch` and reconnect the keyboard (or reboot). The
runtime value is `/sys/module/hid_apple/parameters/fnmode`.

## Troubleshooting

- **No controller in `bluetoothctl list`:** check `lsusb`, `dmesg | grep -i
  blue`, and `rfkill list`. A missing firmware file appears in `dmesg`.
- **Service not running:** `systemctl status bluetooth`,
  `journalctl -u bluetooth -n 50`.
- **Paired but no keypresses:** `dmesg | grep -i hid`; confirm `hid_apple` and
  `hidp` are loaded. Remove/re-pair if the bond is stale.
- **Keyboard types but media keys are wrong:** adjust `fnmode` above.

The Bluetooth daemon runs even with no adapter (a few MB); that is intentional,
so hotplugging a dongle works without another rebuild.