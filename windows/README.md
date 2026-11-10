# Windows 11 slim-image toolkit

Build a lean, unattended Windows 11 ISO without DISM or a Windows build host.

## Docker (containerized)

The build runs in a Debian bookworm container, so nothing is installed on the host.
You only need Docker (Docker Desktop, OrbStack, Colima, or Docker Engine) and a
legally obtained Windows 11 ISO.

```bash
cd windows
./build-win11-docker.sh --iso ~/Downloads/Win11.iso --profile lean
```

The wrapper builds `windows/Dockerfile` on first use (use `--rebuild` to refresh
it), mounts the source ISO read-only, and forwards every option to
`build-win11.sh`. Results land in `windows/out/` with a `.sha256` file next to the
ISO; temporary data stays in `windows/work/`.

```bash
# Conservative, daily-driver image
./build-win11-docker.sh --iso ~/Downloads/Win11.iso --profile safe

# Recommended: smaller installed system, updates still work
./build-win11-docker.sh --iso ~/Downloads/Win11.iso --profile lean --locale de-DE

# Experimental: aggressively stripped; test in a VM first
./build-win11-docker.sh --iso ~/Downloads/Win11.iso --profile micro \
  --experimental --solid --remove-winre --locale de-DE
```

The full guide, including the German version, lives on the website:

- [English guide](https://403access.github.io/nixos/docs/guides/windows-11-slim-image)
- [Deutsche Anleitung](https://403access.github.io/nixos/de/docs/guides/windows-11-slim-image)

## Native (host packages or nix-shell)

On NixOS, or on any system with Nix, the original toolchain works without
Docker. Either install the dependencies system-wide through the installer
(`--windows-toolchain native`, or `myInstall.windows.toolchain = "native"`) and
use the wrapper:

```bash
windows-build --iso ~/Downloads/Win11.iso --profile lean
```

or keep everything ephemeral with `nix-shell`:

```bash
cd windows
nix-shell
./build-win11.sh --iso ~/Downloads/Win11.iso --profile lean
```

The `windows-build` wrapper writes to `~/.local/share/windows-image/out` and
`~/.cache/windows-image/work`, so it works when `/etc/nixos` is not writable.
You can also run `build-win11.sh` directly with explicit writable paths:

```bash
/etc/nixos/windows/build-win11.sh --iso ~/Downloads/Win11.iso --profile lean \
  --out ~/windows-image/out/Win11-lean.iso \
  --workdir ~/windows-image/work
```

To use Docker instead, enable it with `--windows-toolchain docker` (or `both`)
and run the existing wrapper from `/etc/nixos/windows`.

## Profiles

| Profile | What it does |
| --- | --- |
| `safe` | Unattended setup, cache cleanup, recompressed WIM. No app removal. |
| `lean` | `safe` + consumer AppX removal and telemetry policies. Store, Defender and Update stay. |
| `micro` | `lean` + Store, Xbox, OneDrive, search index and SysMain. Requires `--experimental`. |

The script prints a generated local password. Store it before closing the
terminal, or pass `--password`. Empty passwords and `--autologon` are intended
for disposable lab VMs only.

## Requirements

- A legally obtained Windows 11 x64 ISO.
- Docker, or the native packages (`wimlib`, `p7zip`, `xorriso`, `python3`) for a
  native build. The NixOS installer can install them with
  `--windows-toolchain native`; `windows/shell.nix` provides the same tools for
  `nix-shell`.
- About 20 GB free disk space (more with `--solid`).

## What this does not do

- It does not remove Windows Defender, Windows Update, the servicing stack or
  WinSxS. Those changes are unsupported and often break servicing.
- It does not delete `Program Files\WindowsApps` directly. AppX removal happens
  through `Remove-AppxProvisionedPackage` at first boot.
- It does not download Windows. You must provide the ISO.
- It does not activate Windows.

See the website guide for validation, QEMU testing, offline component removal
with DISM/NTLite/MSMG Toolkit, and troubleshooting.
