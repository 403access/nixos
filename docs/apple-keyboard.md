# Apple keyboard on the NixOS host

Host: ASUS **PRIME Z270-A** desktop, NixOS 25.05. Updated **2026-11-22**.

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
and the NixOS host must keep xrdp running. If you need the physical display or
seamless keyboard/mouse sharing instead, use Deskflow/Input Leap or add a USB
Bluetooth dongle.

The Peripherals app will not list the Apple keyboard: it is not on the Logitech
receiver.

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