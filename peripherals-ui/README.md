# NixOS Control Web

Bun + TypeScript + React console for the NixOS Control API. It mirrors the iOS
app: Dashboard, Services, Storage, System, Peripherals and Settings.

Each view has a hash deep link, for example `/#peripherals` opens the receiver
view directly. The `nixos-control.desktop` icon on the NixOS desktop uses
`http://127.0.0.1:3050/#peripherals`.

## Views

- **Dashboard** — host, CPU, memory, load, root disk, services, ZFS pools,
  temperatures, network, Tailscale and a peripherals summary. Click the CPU,
  memory, load or root disk tile for charts and recent history in the side
  panel.
- **Services** — search, filter, start/stop/restart/reload/enable/disable and
  journal logs.
- **Resources** — CPU, memory and disk I/O by service, app and process, with
  sortable tables and per-consumer details.
- **Logs** — parsed journals with severity filters, search, follow-tail,
  collapsible repeats and expandable metadata.
- **Themes** — desktop profile and GTK theme gallery with screenshots, details
  and one-click apply through a rebuild.
- **Storage** — pools, datasets, filesystems and `zpool status`.
- **System** — machine information, `nixos-rebuild` jobs with live output,
  power actions, generations and generation diffs, and the system journal.
- **Peripherals** — read-only Logitech receiver, paired devices, battery,
  signal and firmware.
- **Settings** — server URL, bearer token, connection status and local macOS
  instructions.

## Run against the NixOS API

The API is loopback-only on the host, so the Bun server proxies `/api` to
`127.0.0.1:8787`.

```bash
cd peripherals-ui
bun install
API_TARGET=http://192.168.178.5:8787 bun run dev
```

Open <http://localhost:5173>, leave the server URL empty in Settings, and paste
the token from `sudo nixos-control-token`.

For the NixOS-hosted build, `nixos-control-web.service` serves the dashboard on
port `3050` and proxies to the local API. Open <http://192.168.178.5:3050>.

The iOS app can use the same proxy as its server URL:

```text
http://192.168.178.5:3050
```

That keeps the API on loopback while making every `/api/*` route reachable from
the phone on the LAN.

## Local macOS receiver

To inspect a Logitech receiver plugged into this Mac, use the local launcher:

```bash
cd peripherals-ui
./start-local.sh
```

It builds and starts the Rust API on `http://127.0.0.1:8787`, creates a local
token file at `$TMPDIR/nixos-control-local-token`, and starts Vite. In Settings,
use `http://127.0.0.1:8787` and paste that token.

On macOS the system tabs will be mostly empty because the Linux probes are not
available. The Peripherals view works if the receiver is attached. macOS may ask
for Input Monitoring permission for the terminal before the receiver can be
opened.

## Production build

```bash
bun run build
API_TARGET=http://127.0.0.1:8787 bun run start
```

`bun run start` serves `dist/` and proxies `/api` to the target. It works on
macOS, Linux and Windows.

## Notes

- The receiver view is read-only. It never pairs, unpairs or writes firmware.
- The token and server URL are stored in the browser's `localStorage`.
- The API allows CORS for `/api/health` and `/api/peripherals`; other routes are
  intended to be reached through the same-origin proxy.