# Image Studio: MCP server and image builder

Added **2026-11-22**. [`image-studio/`](../image-studio/README.md) is a
self-contained Node 20+ application with:

- an **MCP stdio server** exposing the Windows/NixOS/offline-image operations
  used in this repository,
- a **local web app** for building custom NixOS and Windows 11 ISOs,
- **bundle export/import** (profile + artifacts + SHA-256),
- a **test suite** (`npm test`) that covers profile rendering, command
  construction, hive/offline safety, MCP, and the HTTP API.

No external Node dependencies are required.

## Architecture

```text
web UI (static HTML/CSS/JS)
        │  fetch /api/*
        ▼
Node HTTP server ── JobManager ── build/trim commands
        │                │
        │                └── logs + artifacts under image-studio/var
        │
        ├── Runner: local or ssh IMAGE_STUDIO_HOST
        ├── LiveSystem: NixOS + Windows PowerShell/SSH
        ├── OfflineImage: qemu-nbd, ntfs-3g, hivexsh, reged
        └── bundles: tar + manifest + checksums

MCP stdio server ── same core modules/tools
```

`IMAGE_STUDIO_HOST` selects SSH mode. With it empty, host/offline commands run
locally; this is why the NixOS module runs the service as root. On a Mac, use
SSH mode plus passwordless keys.

## MCP tools

| Group | Tools |
| --- | --- |
| Info | `image_studio_info`, `system_capabilities`, `host_stats` |
| NixOS | `nixos_config_read`, `nixos_config_write`, `nixos_rebuild`, `nixos_generations`, `nixos_rollback`, `nixos_ksm_status`, `nixos_bluetooth_status`, `nixos_bluetooth_scan`, `nixos_bluetooth_pair` |
| libvirt | `vm_state`, `vm_power`, `vm_memory`, `vm_vcpu` |
| Windows live | `win_verify`, `win_powershell`, `win_ssh_exec`, `win_service_set`, `win_registry_set`, `win_appx_remove`, `win_task_remove`, `win_autologon`, `win_rdp_limits`, `win_recipe`, `win_run_repo_script` |
| Windows offline | `offline_status`, `offline_mount`, `offline_umount`, `offline_backup`, `offline_hive_get`, `offline_hive_set_dword`, `offline_hive_delete_key`, `offline_remove`, `offline_service_set`, `offline_ai_remove`, `offline_harden` |
| Images | `image_profiles`, `image_validate`, `image_build_nixos`, `image_build_windows`, `image_job_list`, `image_job_status`, `image_job_cancel`, `image_bundle_export`, `image_bundle_import`, `image_bundle_list` |
| Tests | `tests_run` |

Destructive tools require explicit confirmations (`RUN`, `WRITE`, `REMOVE`,
`MOUNT`, `UMOUNT`, `BACKUP`, `AI-REMOVE`, `HARDEN`, `POWER`, `RESIZE`,
`REBUILD`, `PAIR`). Passwords are redacted and never returned.

Example OpenCode/Claude configuration is in
[`image-studio/mcp.example.json`](../image-studio/mcp.example.json) and
[`image-studio/opencode.example.json`](../image-studio/opencode.example.json).

## Web API

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/health` | mode, version, capabilities |
| GET | `/api/profiles` | built-in NixOS/Windows presets |
| POST | `/api/validate` | validate/normalize a profile |
| GET/POST | `/api/builds` | list/start build jobs |
| GET | `/api/builds/:id` | job + discovered artifacts |
| GET | `/api/builds/:id/log` | log tail (`?offset=`) |
| POST | `/api/builds/:id/cancel` | cancel |
| GET | `/api/builds/:id/artifacts/:name` | download artifact |
| POST | `/api/uploads` | stream a source ISO |
| POST | `/api/export` | package a completed job |
| POST | `/api/import` | import a `.tar.gz` bundle |
| GET | `/api/bundles` | exported/imported bundles |
| GET | `/api/bundles/:id/download` | download bundle |

The UI is served at `/`; set `IMAGE_STUDIO_TOKEN` for bearer-token protection
when exposing it beyond loopback.

## Build behaviour

- **NixOS:** writes a standalone `configuration.nix` (hostname, user, desktop,
  SSH, libvirt, Bluetooth, KSM, packages), then runs
  `nix-build '<nixpkgs/nixos>' -A config.system.build.isoImage -I
  nixos-config=...`. Desktop profiles import
  `${IMAGE_STUDIO_NIXOS_REPO}/desktop/default.nix`.
- **Windows:** runs `windows/build-win11-docker.sh` with the `safe`/`lean`/`micro`
  profile and the selected flags. Component selections become a post-install
  recipe plan stored in the bundle and applied with `win_recipe`.
- **Bundles:** `manifest.json` + `profile.json` + artifacts under
  `artifacts/`; the manifest records size and SHA-256. Import rejects absolute
  paths, `..`, links and checksum mismatches.

## NixOS module

```nix
{
  imports = [ ./image-studio/module.nix ];
  services.image-studio = {
    enable = true;
    tokenFile = "/var/lib/image-studio/token";
  };
}
```

Default bind is `127.0.0.1:8788`. The module runs as root because qemu-nbd,
mounts and `/etc/nixos` writes require it; keep it on loopback or behind
Tailscale Serve.

## Limitations

- NixOS image builds need a Linux/Nix host.
- Windows builds need Docker or the native wimlib/7z/xorriso toolchain and a
  source ISO.
- Offline hive/payload edits require the NixOS host tools.
- Apple keyboard pairing still requires a Bluetooth adapter and a passkey typed
  on the keyboard.