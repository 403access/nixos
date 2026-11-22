---
title: Peripherals
sidebar_position: 5
description: Read the Logitech receiver, paired devices, battery and firmware from the CLI, API, web dashboard and iOS app.
---

# Peripherals

NixOS Control can read the Logitech receiver attached to the host and show its
paired devices over HID++.

The feature is **read-only**. It does not pair, unpair, change host slots or
write firmware.

## What it shows

- Receiver product, USB ID, path, serial, kind, slot count and firmware.
- Per slot: online state, kind, WPID, serial, name, firmware and battery.
- Signal strength where the device exposes it.
- HID++ 1.0 fallbacks for older devices such as the K800, and HID++ 2.0
  features for devices such as the MX Master.

The Apple Magic Keyboard is **not** part of this link. The Logitech receiver is
not a Bluetooth adapter and cannot enroll it. Use Bluetooth with a USB dongle,
or the keyboard's charging cable. See
[Apple keyboard on the NixOS host](https://github.com/403access/nixos/blob/main/docs/apple-keyboard.md)
for the full explanation.

## CLI

```bash
sudo hidpp-probe
sudo hidpp-probe --json
sudo hidpp-probe --list
sudo hidpp-probe --path /dev/hidraw2
```

`hidpp-probe` is installed by the `nixos-control` package and needs read access
to `/dev/hidraw*`.

Use `--list` to see every Logitech HID collection. On a host with a Unifying
receiver, the receiver is usually `/dev/hidraw2`; paired peripherals have their
own hidraw nodes.

## API

```bash
TOKEN=$(sudo nixos-control-token)
curl -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8787/api/peripherals
```

`GET /api/peripherals` returns the same report as `hidpp-probe --json`.
`/api/health` and `/api/peripherals` allow CORS so a browser can read them; the
other routes remain same-origin.

The systemd unit must run as root to open `/dev/hidraw*`. A `503` with
`Permission denied` means the process cannot open the receiver; a `404` means
the running server predates the endpoint and needs a rebuild and restart.

## Web dashboard

The `peripherals-ui/` directory contains a Bun + TypeScript + React dashboard.

```bash
cd peripherals-ui
bun install
API_TARGET=http://192.168.178.5:8787 bun run dev
```

Open [http://localhost:5173](http://localhost:5173), open **Settings**, leave the server URL empty to
use the Vite proxy, and paste the API token.

For a production build:

```bash
bun run build
API_TARGET=http://192.168.178.5:8787 bun run start
```

Open [http://localhost:4173](http://localhost:4173). The Bun server serves the built app and proxies
`/api` to the NixOS host, so it works on macOS, Linux and Windows.

## iOS

Open **Dashboard → Peripherals** or **System → Peripherals**. The screen uses the
same server URL and token as the rest of the app, and refreshes while it is
visible.

For LAN access without Tailscale, set the iOS server URL to
`http://<LAN-IP>:3050` while the web dashboard is running. The Bun server
proxies `/api` to the loopback Rust API.

## macOS

The same Bun app runs on a Mac. From `peripherals-ui/`:

```bash
./start-local.sh
```

It starts a local Rust API on `http://127.0.0.1:8787`, creates a token file, and
starts Vite. With a receiver plugged into the Mac, the Peripherals view reads it
locally. The system views are mostly empty on macOS because the Linux probes are
unavailable.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `404` on `/api/peripherals` | Deploy the current server and restart `nixos-control`. |
| `503 ... Permission denied` | The process is not root or cannot open the receiver. |
| No receiver found | Run `sudo hidpp-probe --list`; check `lsusb` and `/dev/hidraw*`. |
| Wrong device opened | Force the receiver node with `--path /dev/hidraw2`. |
| Apple keyboard missing | Expected; it is not a Logitech device. |

## Limitations

- Unifying and Nano pairing registers are decoded.
- Bolt receivers are detected and probed through HID++ 2.0, but Bolt pairing
  metadata is not fully decoded yet.
- Pairing, unpairing, host switching and device settings are not implemented in
  this version.