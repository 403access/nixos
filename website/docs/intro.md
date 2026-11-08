---
id: intro
slug: /
title: Introduction
sidebar_label: Introduction
description: An iPhone app and a small authenticated API server for monitoring and managing a NixOS machine.
---

import dashboard from '@site/static/img/screenshots/dashboard.png';
import services from '@site/static/img/screenshots/services.png';
import storage from '@site/static/img/screenshots/storage.png';
import system from '@site/static/img/screenshots/system.png';
import settings from '@site/static/img/screenshots/settings.png';

# NixOS Control

An iPhone app for monitoring and managing a NixOS machine, backed by a small
authenticated API server that runs on the machine itself.

<div style={{display: 'flex', gap: '12px', justifyContent: 'center', alignItems: 'flex-start'}}>
  <img src={dashboard} style={{width: '19%', height: 'auto', borderRadius: '8px'}} alt="Dashboard" />
  <img src={services} style={{width: '19%', height: 'auto', borderRadius: '8px'}} alt="Services" />
  <img src={storage} style={{width: '19%', height: 'auto', borderRadius: '8px'}} alt="Storage" />
  <img src={system} style={{width: '19%', height: 'auto', borderRadius: '8px'}} alt="System" />
  <img src={settings} style={{width: '19%', height: 'auto', borderRadius: '8px'}} alt="Settings" />
</div>

<p align="center"><em>Screenshots use fixture data from the iOS Simulator.</em></p>

## Why

A home server is a wonderful thing until you need to check why a service died,
whether the pool is healthy, or whether last night's rebuild actually switched.
NixOS Control puts those answers on your phone without exposing another web
panel to the internet.

- **Dashboard** — hostname, NixOS/kernel version, uptime, CPU usage, memory,
  load, root disk, ZFS pool health, temperatures, IP addresses, and Tailscale
  state.
- **Services** — search and filter systemd units, start/stop/restart,
  enable/disable at boot, and read journal logs.
- **Storage** — ZFS pool usage and health, `zpool status`, datasets, and
  filesystem usage.
- **System** — NixOS generations, `nixos-rebuild switch/boot/test` with live job
  output and cancellation, reboot, and shutdown.
- **Secure by default** — the server binds to `127.0.0.1`, authenticates every
  request with a 256-bit bearer token, and can be exposed over Tailscale Serve
  with automatic HTTPS. No router ports are opened.
- **Tailscale or WireGuard** — reach the machine through your tailnet, or use
  the WireGuard VPN that already runs on your FRITZ!Box.

## What you need

- A NixOS machine where you can run `nixos-rebuild switch`.
- One way to reach it from your phone: a Tailscale account and client, or an
  existing WireGuard VPN such as the one built into a FRITZ!Box.
- An iPhone on iOS 17 or newer, plus Xcode 26 and
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build the app.

The server has no package dependencies beyond the Go standard library, and Nix
builds it for you.

## How it works

```text
┌─────────────┐      HTTPS (Tailscale)      ┌──────────────────────────┐
│  iPhone app │ ──────────────────────────► │  tailscale serve :443    │
└─────────────┘                             └────────────┬─────────────┘
                                                         │ HTTP localhost
                                                         ▼
                                            ┌──────────────────────────┐
                                            │ nixos-control (Go)       │
                                            │ 127.0.0.1:8787           │
                                            └────────────┬─────────────┘
                                                         │
                                      systemd · journalctl · zfs · nixos-rebuild
                                                         ▼
                                            ┌──────────────────────────┐
                                            │        NixOS host        │
                                            └──────────────────────────┘
```

With Tailscale, the API never listens on a public interface. Tailscale Serve
terminates TLS and forwards requests to loopback, so the phone can reach the
machine anywhere on the tailnet without any inbound firewall rules.

If you use FRITZ!Box WireGuard instead, the server listens on the LAN and the
router's VPN encrypts the path from the phone. Inside the tunnel the API uses
plain HTTP. See [FRITZ!Box WireGuard](./guides/fritzbox-wireguard.md).

## Next steps

- [Server quickstart](./getting-started/quickstart.md) — enable the module and
  verify the API.
- [Build the iOS app](./getting-started/ios-app.md) — generate the Xcode project
  and pair your phone.
- [Configuration](./guides/configuration.md) — every module option.
- [FRITZ!Box WireGuard](./guides/fritzbox-wireguard.md) — use an existing router
  VPN instead of Tailscale.
- [API reference](./reference/api.md) — routes, payloads and authentication.
