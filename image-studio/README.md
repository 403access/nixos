# Image Studio

An MCP server and local web app for the operations used in this repository:
building custom **NixOS ISOs** and **Windows 11 ISOs**, managing the
`win11-stock` libvirt guest, trimming Windows live or offline, editing registry
hives, exporting/importing image bundles, and running the verification suite.

No external Node dependencies. Node 20+.

## What it wraps

| Area | Capabilities |
| --- | --- |
| NixOS host | read/write `configuration.nix`, `nixos-rebuild`, generations, rollback, KSM status, Bluetooth status/scan/pair |
| libvirt | domain state, start/shutdown/destroy, persistent memory and vCPU resize, host/QEMU/RSS stats |
| Windows live | encoded PowerShell or stdin scripts, `win_verify`, services, registry, AppX, scheduled tasks, auto-logon, RDP limits, trim recipes |
| Windows offline | qemu-nbd + NTFS mount, hive backups, `hivexsh` reads, `reged` DWORD writes, key deletion, payload removal, AI-component removal, offline search/Defender hardening |
| Images | profile validation, NixOS ISO builds, Windows ISO builds, job logs/cancel, artifact download |
| Bundles | export a completed job as `.tar.gz` (profile + artifacts + SHA-256), import and verify it, reuse the profile |
| Tests | `node --test` through `tests_run` |

The same code drives the MCP tools and the HTTP API; the web UI is static HTML/CSS/JS.

## Session coverage

| Work done in the VM/NixOS session | MCP tool |
| --- | --- |
| SSH/PowerShell into the Windows guest | `win_ssh_exec`, `win_powershell`, `win_verify` |
| Disable services / set registry / remove AppX / tasks | `win_service_set`, `win_registry_set`, `win_appx_remove`, `win_task_remove` |
| Search/Start-menu/PowerToys/printer/Edge/Store/AI trims | `win_recipe`, `win_run_repo_script` |
| Auto-logon and RDP timeout policy | `win_autologon`, `win_rdp_limits` |
| VM 6→2 vCPU and 8→4 GiB | `vm_vcpu`, `vm_memory`, `vm_state` |
| Shut down, mount raw disk, back up hives | `vm_power`, `offline_mount`, `offline_backup` |
| Hive reads, deletes and `Start` DWORD edits | `offline_hive_get`, `offline_hive_delete_key`, `offline_hive_set_dword` |
| Offline CoreAI/AIFabric removal | `offline_ai_remove` |
| Offline search/Defender hardening | `offline_harden` |
| NixOS config, rebuild, generations, rollback | `nixos_config_read`, `nixos_config_write`, `nixos_rebuild`, `nixos_generations`, `nixos_rollback` |
| KSM persistence and status | `nixos_config_write`, `nixos_ksm_status` |
| Bluetooth/Apple keyboard support | `nixos_bluetooth_status`, `nixos_bluetooth_scan`, `nixos_bluetooth_pair` |
| Build NixOS/Windows images | `image_build_nixos`, `image_build_windows` |
| Export/import results | `image_bundle_export`, `image_bundle_import` |
| Verification/test suite | `win_verify`, `image_job_status`, `tests_run` |

## Quick start

```bash
cd image-studio

# What can this controller/host do?
node bin/image-studio.js doctor

# Start the web UI (loopback only)
node bin/image-studio.js web
# -> http://127.0.0.1:8788
```

For the real NixOS host and Windows guest, point it at SSH targets:

```bash
export IMAGE_STUDIO_HOST=nixos@192.168.178.5
export IMAGE_STUDIO_WIN_HOST=Windows-PC@192.168.122.50
export IMAGE_STUDIO_DOMAIN=win11-stock
export IMAGE_STUDIO_DISK=/var/lib/libvirt/images/win11-stock.raw
export IMAGE_STUDIO_NIXOS_REPO=/etc/nixos
node bin/image-studio.js web
```

The controller needs passwordless SSH to `IMAGE_STUDIO_HOST`, and
`IMAGE_STUDIO_HOST` needs passwordless SSH to the Windows guest (the repo's
`scripts/win-ssh.sh` shows the jump pattern). Offline image operations and
`nixos-rebuild` use `sudo -n`; grant NOPASSWD for the specific commands or run
Image Studio as root on the NixOS host (the NixOS module does the latter).

Use `IMAGE_STUDIO_DRY_RUN=1` to exercise the UI/API without touching anything.

## Web app

- **NixOS tab** — hostname, user, desktop profile, locale/timezone, SSH/libvirt/
  Bluetooth/KSM, packages, image name. Generates a standalone
  `configuration.nix` and runs `nix-build '<nixpkgs/nixos>' -A
  config.system.build.isoImage`.
- **Windows tab** — source ISO (path or upload), safe/lean/micro profile, locale,
  user/computer name, auto-logon, WinRE, solid WIM, themes. Runs
  `windows/build-win11-docker.sh` (or native when `IMAGE_STUDIO_DOCKER=0`).
- **Post-install recipe plan** — Store/Edge/AI/OneDrive/printer/Xbox/search/
  telemetry selections are stored in the bundle and can be applied to a running
  guest with `win_recipe` over MCP.
- **Jobs** — live log, cancel, discovered artifacts, download, export.
- **Import** — drop an Image Studio `.tar.gz`; checksums are verified and the
  embedded profile can be loaded back into the builder.

The build host must have Nix for NixOS images. Windows builds need Docker, or
the native wimlib/7z/xorriso toolchain plus a legally obtained Windows ISO.
Uploaded ISOs are streamed to the controller and copied to the build host when
needed.

## MCP server

Run:

```bash
node src/mcp.js
```

It speaks JSON-RPC 2.0 over stdio (MCP `initialize`, `tools/list`,
`tools/call`, `ping`). See [`mcp.example.json`](mcp.example.json) and
[`opencode.example.json`](opencode.example.json).

Tool groups:

- **Info** — `image_studio_info`, `system_capabilities`, `host_stats`
- **NixOS** — `nixos_config_read`, `nixos_config_write`, `nixos_rebuild`,
  `nixos_generations`, `nixos_rollback`, `nixos_ksm_status`,
  `nixos_bluetooth_status`, `nixos_bluetooth_scan`, `nixos_bluetooth_pair`
- **libvirt** — `vm_state`, `vm_power`, `vm_memory`, `vm_vcpu`
- **Windows live** — `win_verify`, `win_powershell`, `win_ssh_exec`,
  `win_service_set`, `win_registry_set`, `win_appx_remove`, `win_task_remove`,
  `win_autologon`, `win_rdp_limits`, `win_recipe`, `win_run_repo_script`
- **Windows offline** — `offline_status`, `offline_mount`, `offline_umount`,
  `offline_backup`, `offline_hive_get`, `offline_hive_set_dword`,
  `offline_hive_delete_key`, `offline_remove`, `offline_service_set`,
  `offline_ai_remove`, `offline_harden`
- **Images** — `image_profiles`, `image_validate`, `image_build_nixos`,
  `image_build_windows`, `image_job_list`, `image_job_status`,
  `image_job_cancel`, `image_bundle_export`, `image_bundle_import`,
  `image_bundle_list`
- **Tests** — `tests_run`

Destructive tools require an explicit confirmation string (`RUN`, `WRITE`,
`REMOVE`, `MOUNT`, `UMOUNT`, `BACKUP`, `AI-REMOVE`, `HARDEN`, `POWER`,
`RESIZE`, `REBUILD`, `PAIR`). Passwords are accepted only by `win_autologon`,
are redacted from logs, and are never returned.

### Example tool calls

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"win_verify","arguments":{}}}
```

```json
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"image_build_windows","arguments":{"profile":{"name":"lab","profile":"lean","sourceIso":"/var/lib/libvirt/images/Win11.iso","autologon":true}}}}
```

```json
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"offline_ai_remove","arguments":{"confirm":"AI-REMOVE"}}}
```

## Offline image workflow

```text
vm_power(shutdown) -> offline_mount(MOUNT) -> offline_backup(BACKUP)
  -> offline_ai_remove(AI-REMOVE) / offline_hive_set_dword(WRITE)
  -> offline_umount(UMOUNT) -> vm_power(start)
```

`offline_mount` refuses a running domain unless `force=true`, attaches the raw
disk with `qemu-nbd -f raw`, and mounts the NTFS partition. Hive writes are
staged as a `.reg` file and applied with `reged -C -I`; payload removal is
restricted to the mounted Windows root and refuses `Windows/System32/config`.

## NixOS module

```nix
{
  imports = [ ./image-studio/module.nix ];

  services.image-studio = {
    enable = true;
    bind = "127.0.0.1";
    port = 8788;
    host = "";                     # local libvirt/NixOS
    winHost = "Windows-PC@192.168.122.50";
    domain = "win11-stock";
    disk = "/var/lib/libvirt/images/win11-stock.raw";
    nixosRepo = "/etc/nixos";
    tokenFile = "/var/lib/image-studio/token"; # required for non-loopback
  };
}
```

The service runs as root because `qemu-nbd`, mount and `/etc/nixos` writes need
it. Keep it on loopback or put it behind Tailscale Serve, and use a token.

## Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `IMAGE_STUDIO_HOST` | empty | SSH target for libvirt/qemu-nbd/NixOS; empty = local |
| `IMAGE_STUDIO_WIN_HOST` | `Windows-PC@192.168.122.50` | Windows guest SSH target |
| `IMAGE_STUDIO_DOMAIN` | `win11-stock` | libvirt domain |
| `IMAGE_STUDIO_DISK` | `/var/lib/libvirt/images/win11-stock.raw` | raw disk |
| `IMAGE_STUDIO_PARTITION` | `/dev/nbd0p3` | NTFS partition |
| `IMAGE_STUDIO_MOUNT` | `/mnt/win11-offline` | offline mount point |
| `IMAGE_STUDIO_BACKUP` | `/root/image-studio-backups` | hive backups |
| `IMAGE_STUDIO_NIXOS_REPO` | `/etc/nixos` | repo path on the build host |
| `IMAGE_STUDIO_REPO_ROOT` | package parent | controller repo path |
| `IMAGE_STUDIO_DATA` | `image-studio/var` | jobs/uploads/bundles |
| `IMAGE_STUDIO_PORT` | `8788` | web port |
| `IMAGE_STUDIO_BIND` | `127.0.0.1` | web bind address |
| `IMAGE_STUDIO_TOKEN` / `..._TOKEN_FILE` | empty | bearer token |
| `IMAGE_STUDIO_DRY_RUN` | `0` | simulate commands |
| `IMAGE_STUDIO_DOCKER` | `1` | Windows Docker wrapper |
| `IMAGE_STUDIO_SSH_STRICT` | `accept-new` | SSH host key policy |

## Tests

```bash
cd image-studio
npm test
```

33 tests cover profile validation/rendering, Windows/PowerShell command
generation, offline mount/hive safety, bundle checksum/traversal rejection, MCP
protocol, build plans, and web API/auth/export/import.

## Limits

- NixOS ISO builds require a Linux/Nix build host; macOS can run the controller
  and web UI but not the build.
- Windows builds require Docker or the native toolchain and a source ISO.
- Offline editing requires the NixOS host (qemu-nbd, ntfs-3g, hivex, reged).
- The generated NixOS images import `/etc/nixos/desktop/default.nix` when a
  desktop is selected; keep the repo at `IMAGE_STUDIO_NIXOS_REPO`.
- Windows build profiles `safe`/`lean`/`micro` come from the existing builder;
  the extra component selections are recorded as a post-install recipe plan.
- Apple keyboard pairing still needs a Bluetooth adapter and the passkey typed
  on the keyboard; no tool can bypass that.