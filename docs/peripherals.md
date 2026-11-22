# Peripherals

The NixOS host has a Logitech Unifying receiver (`046d:c52b`) with a K800
keyboard and an MX Master mouse. NixOS Control reads that link through HID++ and
exposes it in the CLI, the API, the web dashboard and the iOS app.

The feature is **read-only**. It does not pair, unpair or write firmware.

## Why the Apple keyboard is not listed

The receiver is a 2.4 GHz Logitech endpoint, not a Bluetooth adapter. It only
accepts Logitech devices that completed Logitech pairing. An Apple Magic
Keyboard speaks standard Bluetooth HID and cannot be enrolled by an app. See
[`apple-keyboard.md`](apple-keyboard.md) for the wireless and wired options.

## Components

| Component | Location |
| --- | --- |
| HID++ transport and probe | `server/src/peripherals/` |
| CLI | `server/src/bin/hidpp-probe.rs` |
| API | `GET /api/peripherals` |
| Web dashboard | `peripherals-ui/` |
| iOS screen | `ios/NixOSControl/Views/PeripheralsView.swift` |

## CLI

```bash
sudo hidpp-probe
sudo hidpp-probe --json
sudo hidpp-probe --list
sudo hidpp-probe --path /dev/hidraw2
```

`hidpp-probe` is installed by the `nixos-control` package. It needs read access
to `/dev/hidraw*`, so run it as root or grant the user access.

The report contains:

- receiver product, USB ID, path, serial, kind, slot count and firmware;
- per slot: online state, kind, WPID, serial, name, firmware, battery and signal;
- HID++ 1.0 name/battery/firmware fallbacks for devices such as the K800;
- HID++ 2.0 features for devices such as the MX Master.

`--list` prints every Logitech HID collection. On this host the receiver is
`/dev/hidraw2`; `/dev/hidraw1` is the MX Master and `/dev/hidraw3` is the K800.
Receiver selection prefers known receiver product IDs, so it should not pick a
paired peripheral by mistake.

## API

```bash
TOKEN=$(sudo nixos-control-token)
curl -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8787/api/peripherals
```

`GET /api/peripherals` returns the same object as `hidpp-probe --json`.
`/api/health` and `/api/peripherals` allow CORS so a browser can read them; the
other routes remain same-origin. A missing receiver or a hidraw permission error
returns `503` with an `error` field.

The service must run as root to open the receiver. A normal `nixos` user can
enumerate HID collections but cannot open `0600 root:root` hidraw nodes.

## Deploying

The server package and module in the repository include the endpoint. From the
repository checkout on the host:

```bash
sudo rsync -a --delete server/ /etc/nixos/server/
sudo cp nixos-control.nix /etc/nixos/nixos-control.nix
sudo nixos-rebuild switch
sudo systemctl restart nixos-control
```

The explicit restart is required because the unit has
`restartIfChanged = false`, so a rebuild does not restart the running server.

Verify:

```bash
TOKEN=$(sudo nixos-control-token)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8787/api/peripherals
```

## Web dashboard

```bash
cd peripherals-ui
bun install
API_TARGET=http://192.168.178.5:8787 bun run dev
```

Open <http://localhost:5173>. In **Settings**, leave the server URL empty to use
the Vite proxy and paste the token. A full URL such as
`http://192.168.178.5:8787` also works because `/api/peripherals` is
CORS-enabled.

For a production build:

```bash
bun run build
API_TARGET=http://192.168.178.5:8787 bun run start
```

Open <http://localhost:4173>. The Bun server serves `dist/` and proxies `/api`,
so it works on macOS, Linux or Windows without CORS.

## iOS

Open **Dashboard → Peripherals** or **System → Peripherals**. The screen uses
the same server URL and token as the rest of the app.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `404` on `/api/peripherals` | The running server is older than the endpoint. Deploy and restart the service. |
| `503 ... Permission denied` on `/dev/hidraw2` | The process is not root or cannot open the receiver. The systemd unit runs as root. |
| `no Logitech receiver found` | Run `sudo hidpp-probe --list`; check `lsusb` and `/dev/hidraw*`. |
| The probe opens the K800 instead of the receiver | Use `--path /dev/hidraw2`; receiver selection prefers known receiver product IDs. |
| The Apple keyboard is missing | Expected; it is not a Logitech device. See [`apple-keyboard.md`](apple-keyboard.md). |
| `401 unauthorized` | Read the token again with `sudo nixos-control-token`. |

## Limits

- Unifying and Nano pairing registers are decoded.
- Bolt receivers are detected and their slots are probed through HID++ 2.0, but
  Bolt pairing metadata is not fully decoded yet.
- Pairing, unpairing, host switching and device settings are not implemented in
  this version. Only the read-only snapshot is exposed.