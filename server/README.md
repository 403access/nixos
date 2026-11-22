# nixos-control server (Rust)

The authenticated API used by the iOS app. This crate replaces the original Go
implementation, which is preserved under [`../archive/server-go`](../archive/server-go)
for reference.

## Layout

```text
src/main.rs          CLI entry point and TCP listener
src/api.rs           Axum routes, middleware, request/response shapes
src/jobs.rs          Asynchronous rebuild jobs and 64 KiB output tail buffer
src/commands.rs      Shell-free command execution with timeouts
src/system/          Host probes (status, services, storage, generations, ...)
src/peripherals/     Logitech HID++ receiver probe (read-only)
src/bin/hidpp-probe.rs  Receiver inspector binary
src/util.rs          Parsers, validators and ANSI stripping
tests/api.rs         HTTP contract tests with fixture system/job providers
```

System access is behind the `SystemProbe` trait, command execution behind
`CommandRunner`, and job management behind `JobLauncher`. The HTTP tests inject
mocks for all three, so they never call `systemctl`, `zpool`, or
`nixos-rebuild`.

## Development

```bash
cargo test
cargo clippy --all-targets -- -D warnings
cargo fmt --check
cargo run -- \
  --listen 127.0.0.1:8787 \
  --token-file /tmp/nixos-control-token \
  --allow-rebuild=false \
  --allow-power=false
```

On macOS the API works, but `/proc`, `systemctl`, `journalctl`, `zpool`, and
`nixos-rebuild` are Linux-only, so hardware and system-management responses are
mostly empty.

The NixOS module builds this crate with `rustPlatform.buildRustPackage` and sets
`NIXOS_CONTROL_VERSION`, which the binary reports from `/api/health` and
`/api/status`.

## Logitech receiver probe

`hidpp-probe` is a read-only inspector for Unifying, Nano, and Bolt receivers.
It lists the receiver, its paired slots, device names, firmware, battery and
signal strength where the device exposes them. It never pairs, unpairs or
writes firmware.

```bash
cargo run --bin hidpp-probe
cargo run --bin hidpp-probe -- --json
cargo run --bin hidpp-probe -- --online-only
```

On NixOS the package installs the binary as `hidpp-probe`; run it as root or as
a user with access to `/dev/hidraw*`. The probe uses `hidapi`'s hidraw backend,
so the derivation needs `pkg-config` and `udev` at build time.

Unifying and Nano pairing registers are decoded. Bolt receivers are detected
and their slots are probed through HID++ 2.0, but Bolt pairing metadata is not
fully decoded yet.

The same snapshot is available from `GET /api/peripherals`. That route is
read-only and has CORS enabled for the standalone Bun/React UI; the other API
routes remain same-origin.

## API

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/health` | Version and hostname |
| `GET` | `/api/status` | Full system snapshot |
| `GET` | `/api/peripherals` | Logitech receiver and paired devices (read-only) |
| `GET` | `/api/services` | systemd service units |
| `POST` | `/api/services/{unit}/{action}` | Start/stop/restart/enable/… |
| `GET` | `/api/services/{unit}/logs?lines=200` | Service journal |
| `GET` | `/api/storage` | Pools, datasets, filesystems |
| `GET` | `/api/storage/pools/{name}` | `zpool status` output |
| `GET` | `/api/system/generations` | NixOS generations |
| `POST` | `/api/system/rebuild` | Start a `nixos-rebuild` job |
| `POST` | `/api/system/power` | Reboot, shutdown or power off |
| `GET` | `/api/logs?lines=300` | System journal |
| `GET` | `/api/jobs` | Recent rebuild jobs |
| `GET` | `/api/jobs/{id}` | Job status and output |
| `POST` | `/api/jobs/{id}/cancel` | Cancel a rebuild |

All routes require `Authorization: Bearer <token>`.
