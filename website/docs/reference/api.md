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
| `GET` | `/api/storage/pools/{name}` | `zpool status` output |

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
