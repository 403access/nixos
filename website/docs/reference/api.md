---
title: API reference
sidebar_position: 1
description: HTTP routes exposed by the nixos-control server.
---

# API reference

Every route requires a bearer token:

```http
Authorization: Bearer <token>
```

The server listens on `127.0.0.1:8787` by default and returns JSON.

## Health and status

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/health` | Version and hostname |
| `GET` | `/api/status` | Full system snapshot |
| `GET` | `/api/status/history?minutes=60` | In-memory status history for charts |
| `GET` | `/api/resources` | CPU, memory, disk and network I/O by consumer |
| `GET` | `/api/themes` | Desktop theme catalog and current selection |
| `POST` | `/api/themes/apply` | Apply a profile or GTK theme |
| `GET` | `/api/logs?lines=300` | System journal |

### `GET /api/health`

```json
{"ok": true, "version": "0.1.0", "hostname": "nixos"}
```

### `GET /api/status`

Returns the capabilities reported to the app (rebuild and power availability)
plus host metrics: NixOS and kernel versions, uptime, CPU, memory, load, root
disk, ZFS pool health, temperatures, IP addresses, and Tailscale state.

### `GET /api/status/history`

Returns the samples the server keeps in memory for the dashboard charts. The
sampler records one point every 10 seconds and keeps up to six hours.

```http
GET /api/status/history?minutes=60&limit=720
```

```json
{
  "samples": [
    {
      "at": "2026-11-23T03:50:10Z",
      "cpu": {"model": "AMD Ryzen 7", "cores": 8, "usage_percent": 12.5},
      "load": [0.52, 0.44, 0.31],
      "memory": {"total": 33554432000, "used": 11274289152, "...": 0},
      "root_disk": {"mount": "/", "total": 1000000000, "used": 400000000, "available": 600000000, "use_percent": 40.0},
      "services": {"running": 120, "failed": 0, "total": 220},
      "generation": 98,
      "uptime_seconds": 7200,
      "temperatures": [{"label": "CPU", "celsius": 41.0}],
      "pools": []
    }
  ]
}
```

History is not persisted across server restarts.

### `GET /api/resources`

Returns the latest resource attribution sample. The server reads `/proc` every
five seconds and reports CPU, resident memory, block I/O and network traffic for
systemd services/scopes, applications grouped by executable, and individual
processes. Network rates are derived from the TCP socket counters reported by
`ss -i`, attributed to the owning process; UDP traffic is not counted.

```json
{
  "at": "2026-11-23T04:12:30Z",
  "interval_ms": 5000,
  "cpu_count": 8,
  "memory_total": 33508700160,
  "total_cpu_percent": 42.5,
  "total_memory_bytes": 3221225472,
  "total_read_bps": 1024.0,
  "total_write_bps": 2048.0,
  "total_network_rx_bps": 65536.0,
  "total_network_tx_bps": 32768.0,
  "services": [
    {
      "name": "nixos-control",
      "kind": "service",
      "unit": "nixos-control.service",
      "tasks": 10,
      "cpu_percent": 0.4,
      "memory_bytes": 14680064,
      "read_bps": 0.0,
      "write_bps": 0.0,
      "network_rx_bps": 0.0,
      "network_tx_bps": 0.0
    }
  ],
  "apps": [
    {
      "name": "qemu-system-x86_64",
      "kind": "app",
      "unit": "machine-qemu-8-win11-stock.scope",
      "tasks": 17,
      "cpu_percent": 39.2,
      "memory_bytes": 1939865600,
      "read_bps": 0.0,
      "write_bps": 0.0,
      "network_rx_bps": 0.0,
      "network_tx_bps": 0.0
    }
  ],
  "processes": [
    {
      "pid": 54655,
      "name": "qemu-system-x86_64",
      "command": "qemu-system-x86_64 -name guest=win11-stock",
      "unit": "machine-qemu-8-win11-stock.scope",
      "kind": "machine",
      "cpu_percent": 39.2,
      "memory_bytes": 1939865600,
      "read_bps": 0.0,
      "write_bps": 0.0,
      "network_rx_bps": 0.0,
      "network_tx_bps": 0.0
    }
  ]
}
```

CPU percentages are relative to one core and can exceed 100%. Memory is RSS
summed per process; disk values are actual block I/O. Network values are TCP
payload rates attributed from per-socket counters. The first sample after a
server start has no CPU/I/O or network deltas yet.

### `GET /api/resources/history`

Returns per-entity time series from the in-memory resource history. Samples are
taken every five seconds and kept for up to one hour.

```http
GET /api/resources/history?kind=services&minutes=15&metric=cpu&top=8
```

- `kind`: `services` or `apps`
- `minutes`: 1–60
- `metric`: `cpu`, `memory`, `read`, `write`, `rx` or `tx` (also selects the
  top entities)
- `top`: 1–12
- `entities`: optional comma-separated keys (`unit` for services, `name` for
  apps) to return specific timelines

```json
{
  "from": "2026-11-23T04:10:00Z",
  "to": "2026-11-23T04:25:00Z",
  "kind": "services",
  "series": [
    {
      "key": "nixos-control.service",
      "name": "nixos-control",
      "kind": "service",
      "points": [
        {"at": "2026-11-23T04:10:00Z", "cpu_percent": 0.4, "memory_bytes": 14680064, "read_bps": 0.0, "write_bps": 0.0, "network_rx_bps": 0.0, "network_tx_bps": 0.0}
      ]
    }
  ],
  "totals": [
    {"at": "2026-11-23T04:10:00Z", "cpu_percent": 42.5, "memory_bytes": 3221225472, "read_bps": 1024.0, "write_bps": 2048.0, "network_rx_bps": 65536.0, "network_tx_bps": 32768.0}
  ]
}
```

## Services

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/services` | systemd service units |
| `POST` | `/api/services/{unit}/{action}` | Unit action |
| `GET` | `/api/services/{unit}/logs?lines=200` | Service journal |

Supported actions: `start`, `stop`, `restart`, `reload`, `enable`, `disable`,
`reset-failed`.

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8787/api/services/nginx/restart
```

## Storage

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/storage` | Pools, datasets, filesystems |
| `GET` | `/api/storage/files?root=/&path=/home` | Read-only directory listing and search |
| `GET` | `/api/storage/pools/{name}` | `zpool status` output |

### File explorer

`GET /api/storage/files` lists one directory inside a selected filesystem. The
path must stay inside `root`; symlinks are resolved and anything outside the
selected mount is rejected. Directories are returned first.

- `root` (required): absolute mountpoint selected on the Storage page
- `path`: absolute directory to list, defaults to `root`
- `q`: case-insensitive name search, recursive up to 8 levels
- `sort`: `name`, `size`, `modified` or `type`
- `order`: `asc` or `desc`
- `filter`: `all`, `files` or `dirs`
- `hidden`: `true` to include dotfiles

```json
{
  "root": "/",
  "path": "/home/nixos",
  "parent": "/home",
  "total": 2,
  "truncated": false,
  "entries": [
    {
      "name": "Desktop",
      "path": "/home/nixos/Desktop",
      "kind": "dir",
      "size": 0,
      "modified": "2026-11-23T04:12:30Z",
      "hidden": false
    },
    {
      "name": "notes.txt",
      "path": "/home/nixos/notes.txt",
      "kind": "file",
      "size": 128,
      "modified": "2026-11-22T18:01:00Z",
      "hidden": false
    }
  ]
}
```

Listings are capped at 2000 entries and searches at 500 results, 20,000 visited
entries or 1.5 seconds; `truncated` is set when a limit is reached.

## System

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/system/generations` | NixOS generations |
| `GET` | `/api/system/generations/diff?from=91&to=93` | Package-level diff between two generations |
| `POST` | `/api/system/rebuild` | Start a rebuild job |
| `GET` | `/api/jobs` | List rebuild jobs |
| `GET` | `/api/jobs/{id}` | Rebuild job status and output |
| `POST` | `/api/jobs/{id}/cancel` | Cancel a running job |
| `POST` | `/api/system/power` | Reboot or shut down |

### Generation diff

`GET /api/system/generations/diff?from=91&to=93` compares the package closures
of two NixOS generations with `nix store diff-closures`. The response contains
structured entries plus the raw, ANSI-free output.

```json
{
  "from": 91,
  "to": 93,
  "added": 2,
  "removed": 1,
  "changed": 3,
  "entries": [
    {
      "name": "glibc",
      "change": "changed",
      "before": "2.39-52",
      "after": "2.39-66",
      "size": "+12.0 KiB",
      "line": "glibc: 2.39-52 → 2.39-66, +12.0 KiB"
    }
  ],
  "lines": ["glibc: 2.39-52 → 2.39-66, +12.0 KiB"],
  "truncated": false
}
```

Both apps expose this from **System → Generations → Compare generations**.

### Rebuild

```http
POST /api/system/rebuild
Content-Type: application/json

{"action": "switch"}
```

Allowed actions: `switch`, `boot`, `test`, `dry-activate`, `dry-build`.

The server responds with `202 Accepted` and a job object. Poll
`GET /api/jobs/{id}` for status and incremental output.

### Power

```http
POST /api/system/power
Content-Type: application/json

{"action": "reboot"}
```

Allowed actions: `reboot`, `shutdown`, `poweroff`.

## Logs

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/logs?lines=300` | Parsed system journal |
| `GET` | `/api/services/{unit}/logs?lines=200` | Parsed unit journal |

Both endpoints use `journalctl -o json` and return human-readable `lines` plus
structured `entries`:

```json
{
  "lines": ["2026-11-23T04:20:00Z warning nginx[123]: upstream slow"],
  "entries": [
    {
      "timestamp": "2026-11-23T04:20:00Z",
      "priority": 4,
      "level": "warning",
      "message": "upstream slow",
      "identifier": "nginx",
      "unit": "nginx.service",
      "pid": 123,
      "hostname": "nixos",
      "transport": "stdout",
      "comm": "nginx",
      "exe": "/nix/store/.../nginx"
    }
  ]
}
```

The web and iOS apps use the structured entries for severity colours, filters,
search, follow-tail, repeat collapsing and expandable metadata.

## Themes

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/themes` | Theme catalog and current selection |
| `POST` | `/api/themes/apply` | Select a profile, GTK theme or wallpaper |

`GET /api/themes` returns the current theme plus desktop profile, GTK theme and
wallpaper cards with names, descriptions, details, accent colours, screenshot
names and `current` flags. The current selection includes a `wallpaper` preset
(`catppuccin` or `whitesur`).

```http
POST /api/themes/apply
Content-Type: application/json

{"profile": "plasma"}
```

```json
{"profile": "plasma", "gtkTheme": "catppuccin", "wallpaper": "whitesur"}
```

At least one field is required. Selecting a GTK theme also selects its matching
wallpaper unless `wallpaper` is given explicitly. The server writes
`/etc/nixos/desktop/selected.nix` with `lib.mkForce` settings and starts a
`nixos-rebuild switch` job. The response is `202 Accepted` with the target theme
and the job; poll `/api/jobs/{id}` for output. Theme changes require
`allowRebuild` to be enabled. The active selection is read from
`/etc/nixos-control/theme.json`, written by the desktop module.

### `POST /api/rdp/reset`

Terminates stale xrdp sessions, removes their leftover X sockets and restarts
`xrdp-sesman` and `xrdp`. This fixes the black-screen/disconnect loop that can
happen when a rebuild restarts xrdp while the old desktop session is still
alive. The theme apply handler runs the same reset automatically after a
successful rebuild.

```http
POST /api/rdp/reset
Content-Type: application/json

{"force": true}
```

`force` defaults to `true`, which terminates every xrdp session. Send
`{"force": false}` to clean up only sessions in a stale state. The response
contains the command output:

```json
{
  "status": "ok",
  "force": true,
  "exit_code": 0,
  "output": "Terminating xrdp session 218 (state=closing, display=:10)\nRestarting xrdp-sesman and xrdp\nRDP reset finished (terminated=1)\n"
}
```

## Sessions

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/sessions?limit=50` | App action sessions and host logins |
| `GET` | `/api/sessions/{id}?lines=300` | Session actions, logs and shell history |

The API server records mutating requests and groups them into sessions per
client. The audit trail is kept in `/var/lib/nixos-control/activity.jsonl`, so
it survives server restarts. Host sessions come from `loginctl`; their detail
includes the session journal and shell commands.

When `services.nixos-control.commandLog.enable` is true (the default), an
interactive bash/zsh hook appends commands to
`~/.local/state/nixos-control/commands.jsonl`. Each command entry includes
`at`, `duration_ms`, `exit_code`, `status` (`ok`, `failed` or `unknown`),
`cwd`, `tty` and `source` (`log` or `history`). Older commands recovered from
shell history may omit timing and exit status.

```json
{
  "sessions": [
    {
      "id": "login-2",
      "kind": "login",
      "source": "ssh",
      "title": "oliver · tty1",
      "user": "oliver",
      "remote_host": "192.168.1.20",
      "service": "sshd",
      "state": "active",
      "started_at": "2026-11-22T23:00:00Z",
      "last_active_at": "2026-11-22T23:00:00Z",
      "action_count": 4,
      "status": "ok",
      "summary": "Remote login from 192.168.1.20 · 4 commands"
    },
    {
      "id": "app-19a2c4d5e6f-0",
      "kind": "app",
      "source": "web",
      "title": "Web console",
      "remote_host": "100.64.0.7",
      "state": "online",
      "started_at": "2026-11-22T23:04:11Z",
      "last_active_at": "2026-11-22T23:05:02Z",
      "action_count": 2,
      "status": "ok",
      "summary": "restart nginx.service · rebuild switch"
    }
  ]
}
```

Application session detail returns an `actions` array, with captured `job_id`
and `output` for rebuilds. Login session detail returns `logs` from the journal
and `commands` from the shell audit log:

```json
{
  "at": "2026-11-23T03:12:04Z",
  "command": "nixos-rebuild switch",
  "duration_ms": 48210,
  "exit_code": 0,
  "status": "ok",
  "cwd": "/etc/nixos",
  "source": "log"
}
```

Older commands recovered from shell history carry `source: "history"` and may
omit `duration_ms` and `exit_code`.

## Peripherals

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/peripherals` | Logitech receiver and paired devices (read-only) |

Returns the same report as `hidpp-probe --json`: receiver metadata, paired
slots, device names, battery, signal and firmware. The route is read-only and
never pairs, unpairs or writes firmware.

`/api/health` and `/api/peripherals` allow CORS so the standalone
`peripherals-ui` dashboard can read them; the other routes remain same-origin.
A missing receiver or a hidraw permission error returns `503` with an `error`
field.

See [Peripherals](../guides/peripherals.md) for the CLI, web dashboard and iOS
screen.

## Errors

| Status | Meaning |
| --- | --- |
| `400` | Invalid JSON body, unit name, pool name, or action |
| `401` | Missing or invalid bearer token |
| `403` | Action disabled by module configuration |
| `404` | Unknown job or route |
| `500` | Command or system error |
| `503` | Token file, receiver, or hidraw access unavailable |

Errors are returned as JSON with an `error` field.
