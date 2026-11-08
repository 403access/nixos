---
title: Architecture
sidebar_position: 2
description: Components, trust boundaries and data flow.
---

# Architecture

NixOS Control has three parts:

1. **iOS app** — a SwiftUI client with five tabs. It stores the server URL in
   `UserDefaults` and the bearer token in the Keychain.
2. **API server** — a dependency-free Go program that runs on the NixOS host and
   shells out to system tools.
3. **NixOS module** — builds the server, manages the token file, and runs the
   API plus an optional Tailscale Serve proxy.

## Data flow

```text
iPhone ──HTTPS──► tailscale serve :443 ──HTTP──► nixos-control 127.0.0.1:8787
                                                        │
                                                        ├── systemctl
                                                        ├── journalctl
                                                        ├── zfs / zpool
                                                        └── nixos-rebuild
```

- The phone talks to the machine over the tailnet using its MagicDNS HTTPS name.
- Tailscale terminates TLS and forwards to loopback.
- The Go server authenticates the bearer token, then invokes system commands
  with argument arrays (no shell interpolation of user input).
- Results are returned as JSON.

## Trust boundaries

| Boundary | Control |
| --- | --- |
| Phone → host | Tailscale identity, WireGuard encryption, HTTPS |
| HTTP → API | 256-bit bearer token, constant-time comparison |
| API → system | root-owned unit, fixed command allowlist |
| Tailnet → port 443 | Tailscale ACLs |

The token is the only application-level credential. Anyone who has it can
perform every action the module allows.

## Process model

- The server is a single Go binary with no external Go modules.
- Rebuild jobs run asynchronously and are kept in memory. Restarting the server
  loses job history.
- Status and logs are polled by the app; there is no streaming endpoint.
- Single-host only.

## Repository layout

```text
configuration.nix          Existing NixOS config (imports the module)
nixos-control.nix          NixOS module: packages and runs the server
server/                    Dependency-free Go API server
ios/                       SwiftUI app and XcodeGen project
website/                   Marketing site and documentation (Docusaurus)
docs/screenshots/          App screenshots used in the README
```

## Design constraints

- No database, message queue, or background daemon beyond systemd.
- No cloud service, account, or telemetry.
- The API server is intentionally not restarted during `nixos-rebuild`, so an
  in-flight rebuild cannot kill its own process.
