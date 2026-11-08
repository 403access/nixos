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
| `GET` | `/api/logs?lines=300` | System journal |

### `GET /api/health`

```json
{"ok": true, "version": "0.1.0", "hostname": "nixos"}
```

### `GET /api/status`

Returns the capabilities reported to the app (rebuild and power availability)
plus host metrics: NixOS and kernel versions, uptime, CPU, memory, load, root
disk, ZFS pool health, temperatures, IP addresses, and Tailscale state.

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
| `POST` | `/api/system/rebuild` | Start a rebuild job |
| `GET` | `/api/jobs` | List rebuild jobs |
| `GET` | `/api/jobs/{id}` | Rebuild job status and output |
| `POST` | `/api/jobs/{id}/cancel` | Cancel a running job |
| `POST` | `/api/system/power` | Reboot or shut down |

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

## Errors

| Status | Meaning |
| --- | --- |
| `400` | Invalid JSON body, unit name, pool name, or action |
| `401` | Missing or invalid bearer token |
| `403` | Action disabled by module configuration |
| `404` | Unknown job or route |
| `500` | Command or system error |
| `503` | Token file is not available |

Errors are returned as JSON with an `error` field.
