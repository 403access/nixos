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

## API

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/health` | Version and hostname |
| `GET` | `/api/status` | Full system snapshot |
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
