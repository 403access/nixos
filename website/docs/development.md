---
title: Development
sidebar_position: 3
description: Run the server, app and website locally.
---

# Development

## Server

```bash
cd server
cargo test
cargo run -- \
  --listen 127.0.0.1:8787 \
  --token-file /tmp/nixos-control-token \
  --allow-rebuild=false \
  --allow-power=false
```

The server is a Rust crate with a locked dependency set (`Cargo.lock`). It is
built by NixOS with `buildRustPackage`. The original Go implementation remains
under `archive/server-go/` as a reference and still passes `go test ./...`.

Running it on macOS is enough for API work, but `/proc`, `systemctl`,
`journalctl` and `zpool` are Linux-only, so the dashboard and system endpoints
stay empty.

## Local NixOS VM

The module needs a real NixOS userspace. With [OrbStack](https://orbstack.dev):

```bash
./vm/vm.sh up          # create the machine if needed, sync, nixos-rebuild switch
./vm/vm.sh status      # units, token prefix, API health, URLs
```

The machine is called `control-test`; `ORB_MACHINE=my-vm` overrides it. You get:

- the API at `http://control-test.orb.local:8787`,
- an XFCE desktop over VNC at `vnc://control-test.orb.local:5901` (password
  `nixos`), opened with `./vm/vm.sh vnc`,
- the real systemd unit, token generation, journal and `/proc`.

Other helpers: `ip`, `shell`, `root`, `token`, `ios [tab]`, `vnc`, `logs`,
`stop`, `start` and `delete`. `./vm/apply.sh` performs just the sync and
`nixos-rebuild switch`. See
[`vm/README.md`](https://github.com/403access/nixos/blob/main/vm/README.md) for
the wrapper layout and caveats.

Launch the app against the VM with:

```bash
./vm/vm.sh ios services
```

That builds for the booted iPhone simulator (or boots `iPhone 17`), installs the
app, and sets `NIXOS_CONTROL_SERVER`, `NIXOS_CONTROL_TOKEN` and
`NIXOS_CONTROL_TAB`.

:::note
The machine runs the `lxc-container` module on OrbStack's shared kernel, so
kernel, initrd, bootloader and hardware configuration are not exercised, and
ZFS is unavailable. Tailscale Serve is disabled because it needs a real tailnet.
`POST /api/system/rebuild` targets `/etc/nixos`, which is OrbStack's base
config — use `dry-build` while testing.
:::

## iOS

```bash
cd ios
xcodegen generate
xcodebuild -project NixOSControl.xcodeproj \
  -scheme NixOSControl \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
```

## Website

The website lives in `website/` and contains both the marketing page at `/` and
this documentation at `/docs`.

```bash
cd website
npm install
npm run start
```

`npm run start` serves the site at `http://localhost:3000/nixos/` by default.
The marketing page is the root route; documentation is under `/docs`.

Build and preview the production output:

```bash
npm run build
npm run serve
```

### Deployment

Every push to `main` triggers the **Deploy website** GitHub Actions workflow. It
builds `website/` and publishes the result to GitHub Pages using the official
Pages actions.

One-time repository setup:

1. Open **Settings → Pages**.
2. Set **Build and deployment → Source** to **GitHub Actions**.

The project site is published at `https://403access.github.io/nixos/`. To use a
custom domain at the domain root, set the `SITE_BASE_URL` environment variable
to `/` in the workflow and add a `static/CNAME` file with your domain.

## Repository conventions

- Keep the Rust server's dependency set small and locked in `server/Cargo.lock`.
- Update `website/docs/` when behaviour changes; the docs deploy with the site.
- Screenshots used by the site are copied to `website/static/img/screenshots/`.
