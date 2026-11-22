# Peripherals UI

A small Bun + TypeScript + React dashboard for the Logitech receiver attached to
the NixOS host. It reads the same read-only HID++ snapshot as `hidpp-probe` via
`GET /api/peripherals`.

## Development

```bash
cd peripherals-ui
bun install
bun run dev
```

Open <http://localhost:5173>. In Settings, leave the server URL empty to use the
Vite proxy, or enter the API URL directly:

```text
http://192.168.178.5:8787
```

The token is the bearer token from the NixOS host:

```bash
sudo nixos-control-token
```

Set the proxy target with `API_TARGET` if the API is not on localhost:

```bash
API_TARGET=http://192.168.178.5:8787 bun run dev
```

## Production build

```bash
bun run build
API_TARGET=http://192.168.178.5:8787 bun run start
```

`bun run start` serves `dist/` on <http://localhost:4173> and proxies `/api` to
the target, so no CORS or extra web server is needed. To serve the static build
from another web server, leave the server URL empty and point that server's
`/api` proxy at the NixOS API, or enter a full API URL in Settings.

## Notes

- The view is read-only. It never pairs, unpairs or writes firmware.
- The API token and server URL are stored in `localStorage` for convenience.
- The Rust API allows CORS for `/api/peripherals` only, so direct browser calls
  work without exposing the other management endpoints cross-origin.