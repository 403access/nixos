# Local test VM (OrbStack)

Run the real NixOS module, the real systemd unit, and the real Rust server on a
throwaway Linux machine on the Mac — no remote builder, no UTM install, no
`socat` port forwarding.

```bash
./vm/vm.sh up          # create the machine if needed, sync, nixos-rebuild switch
```

Requires [OrbStack](https://orbstack.dev) with the `orb` CLI. Everything uses
`control-test` by default; override with `ORB_MACHINE=my-vm ./vm/vm.sh …`.

## Commands

| Command | What it does |
| --- | --- |
| `./vm/vm.sh up` | create and start the machine, then `nixos-rebuild switch` |
| `./vm/vm.sh desktop <profile>` | switch to `rice` (default), `plasma`, or `xfce` and rebuild |
| `./vm/vm.sh status` | machine state, desktop profile, unit states, token prefix, API health, URLs |
| `./vm/vm.sh ip` | print the machine's address |
| `./vm/vm.sh shell` / `root` | interactive shell (as `olivermolnar` / `root`) |
| `./vm/vm.sh token` | print the API token |
| `./vm/vm.sh ios [tab]` | build, install, and launch the app against the machine |
| `./vm/vm.sh vnc` | open the desktop in Screen Sharing |
| `./vm/vm.sh logs` | `journalctl -u nixos-control -f` |
| `./vm/vm.sh stop` / `start` | pause / resume (the disk is kept) |
| `./vm/vm.sh delete` | destroy the machine (OrbStack asks for confirmation) |

`./vm/apply.sh` is the sync-and-rebuild step on its own; `vm.sh up` calls it.
Raw `orb` commands work too (`orb stop control-test`, `orb delete control-test`).

> After `stop`/`start`, OrbStack's `<machine>.orb.local` mDNS record can keep
> advertising the previous address for a few minutes. The helpers fall back to
> the machine IP for the API check, VNC, and the iOS launch URL.

## What you get

- `http://control-test.orb.local:8787` — the API, reachable from macOS and from
  the iOS Simulator without any port forwarding.
- `vnc://control-test.orb.local:5901` — the selected desktop profile (the
  Catppuccin i3 `rice` by default; password `nixos`).
- `control-test.orb.local` — SSH is disabled; use `orb -m control-test` to get a
  shell, or `orb -m control-test sudo …` for root commands.
- Token: `./vm/vm.sh token`
  (or `nixos-control-token` inside the machine).

## Desktop profiles

The VM defaults to the `rice` profile: i3, polybar, picom, Rofi, dunst, xterm
and the Catppuccin Mocha theme. Switch without recreating the machine:

```bash
./vm/vm.sh desktop rice      # Catppuccin i3 (default)
./vm/vm.sh desktop plasma    # KDE Plasma 6
./vm/vm.sh desktop xfce      # original XFCE
```

The X11 VNC display cannot show Hyprland, which is Wayland-only. The root
[README](../README.md#desktop-profiles) has screenshots, keybindings and the
full option reference.

## Visual access

```bash
./vm/vm.sh vnc
```

or open **Finder → Go → Connect to Server** and enter:

```text
vnc://control-test.orb.local:5901
```

or from a terminal:

```bash
open vnc://control-test.orb.local:5901
```

The password is `nixos` (change `vncPassword` in `configuration.nix` if the
machine is reachable from untrusted networks). The same password is set for the
`vnc` Linux user, so Plasma's lock screen and i3lock can unlock with
`vnc` / `nixos`. Any standard VNC client works; the desktop is the selected
profile. The default `rice` profile opens with `Super+Return` (xterm),
`Super+D` (Rofi), `Super+B` (Firefox) and `Super+Shift+X` (power menu).

> If Screen Sharing reports "Unable to communicate", check that the VNC port is
> reachable (`nc -vz <host> 5901`). OrbStack's `<machine>.orb.local` name can be
> stale after `stop`/`start`; `./vm/vm.sh vnc` probes it and falls back to the
> machine IP. The guest firewall only admits the API port opened by the module
> and `vncPort` from `configuration.nix`.

VNC runs inside the machine as the unprivileged `vnc` user. The desktop is
useful for poking at the API with `curl`, watching `journalctl -f`, or running
`nixos-rebuild` by hand while the app talks to the same server.

## Point the iOS app at it

`AppState` reads debug overrides from the environment, so no UI setup is
needed:

```bash
./vm/vm.sh ios            # dashboard tab
./vm/vm.sh ios services   # any of dashboard/services/storage/system/settings
```

That generates the project, builds for the first booted iPhone simulator (or
boots `iPhone 17`), installs, and launches with the server URL, token, and tab
already set. The equivalent by hand:

```bash
cd ios
xcodegen generate

xcodebuild -project NixOSControl.xcodeproj -scheme NixOSControl \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

xcrun simctl boot 'iPhone 17' 2>/dev/null || true
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/NixOSControl.app

TOKEN=$(orb -m control-test sudo cat /var/lib/nixos-control/token)
SIMCTL_CHILD_NIXOS_CONTROL_SERVER=http://control-test.orb.local:8787 \
SIMCTL_CHILD_NIXOS_CONTROL_TOKEN=$TOKEN \
SIMCTL_CHILD_NIXOS_CONTROL_TAB=dashboard \
xcrun simctl launch --terminate-running-process booted com.olivermolnar.nixoscontrol
```

The overrides only apply to `DEBUG` builds (the default for `xcodebuild`).

## How the script works

`apply.sh` copies `server/`, `nixos-control.nix`, `desktop/`, and
`vm/configuration.nix` into the machine's `/etc/nixos`, writes the selected
profile to `/etc/nixos/vm/desktop.nix`, and generates
`/etc/nixos/control-test.nix`:

```nix
{
  imports = [
    ./configuration.nix        # OrbStack's own config: networking, users, lxc boot
    ./vm/configuration.nix     # this repo's test module
    ./vm/desktop.nix           # myDesktop.profile = "rice" | "plasma" | "xfce"
  ];
}
```

That wrapper matters: replacing OrbStack's configuration wholesale removes its
network setup and the machine loses connectivity on activation. Importing it
keeps the machine reachable while the repo's module is layered on top.

## Limitations

- **Kernel and boot are OrbStack's.** The machine runs the `lxc-container`
  module on OrbStack's shared kernel, so kernel modules, initrd, bootloader,
  and `hardware-configuration.nix` are not exercised.
- **No ZFS.** There are no zpool tools or ZFS kernel modules, so `/api/storage`
  shows filesystems but no pools or datasets. Test ZFS on the real host.
- **No Tailscale.** `tailscaleServe` is disabled; the Serve path needs a real
  tailnet and a login.
- **The VNC display is X11.** `rice`, `plasma`, and `xfce` work over it;
  Hyprland is Wayland-only and is intentionally rejected by an assertion in
  `vm/configuration.nix`. OrbStack exposes no DRM device, so a headless
  Hyprland session cannot start either; use `./switch-hyprland.sh` on the real
  host (see the root README) and test Hyprland on hardware.
- **The VM has no GPU.** Mesa uses `llvmpipe`, GLX is unavailable, and Kitty
  cannot open a window. The rice uses xterm (and `Super+Shift+Return` still
  tries Kitty). Plasma runs with software rendering, but is heavier and less
  representative of hardware.
- **Rebuild endpoint targets `/etc/nixos`.** `POST /api/system/rebuild` runs
  `nixos-rebuild` in `/etc/nixos`, which is OrbStack's base configuration — a
  `switch` from the app would remove `nixos-control`. Use `dry-build` or
  `dry-activate` while testing, or set `services.nixos-control.flake` to a
  flake that returns this test configuration.
- **Power actions really power off the machine.** Reboot/shutdown work, they
  just take the VM down with them.
- **Apple Silicon has no nested KVM**, so `nixosTest` / `build-vm` cannot run
  inside this machine. Use the NixOS host or a KVM-enabled CI runner for those.
