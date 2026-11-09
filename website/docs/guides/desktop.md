---
title: Desktop profiles
sidebar_position: 2
description: Choose between the original XFCE, a Catppuccin i3 rice, KDE Plasma 6 and Hyprland.
---

import rice from '@site/static/img/screenshots/desktop-rice.png';
import plasma from '@site/static/img/screenshots/desktop-plasma.png';

# Desktop profiles

The repository now includes a small `myDesktop` module alongside the API
server. It keeps the original XFCE setup as the default, but lets you switch
the whole desktop with one option — no separate config to maintain.

<div style={{display: 'flex', gap: '1rem', flexWrap: 'wrap', margin: '1.5rem 0'}}>
  <figure style={{flex: '1 1 320px', margin: 0}}>
    <img src={rice} style={{width: '100%', borderRadius: '12px'}} alt="The Catppuccin i3 rice profile" />
    <figcaption style={{textAlign: 'center', fontSize: '0.85rem', opacity: 0.8}}>
      <strong>rice</strong> — i3, polybar, picom, Rofi and xterm
    </figcaption>
  </figure>
  <figure style={{flex: '1 1 320px', margin: 0}}>
    <img src={plasma} style={{width: '100%', borderRadius: '12px'}} alt="KDE Plasma 6 with the Catppuccin theme" />
    <figcaption style={{textAlign: 'center', fontSize: '0.85rem', opacity: 0.8}}>
      <strong>plasma</strong> — KDE Plasma 6 with the Catppuccin theme
    </figcaption>
  </figure>
</div>

## Profiles

| Profile | Session | What you get |
| --- | --- | --- |
| `xfce` | X11 | The original XFCE desktop, now with the Catppuccin GTK theme, icons, cursor and fonts. |
| `rice` | X11 | A Catppuccin Mocha i3 desktop: polybar, picom, Rofi, dunst, xterm, Thunar and Firefox. Works over VNC and xrdp. |
| `plasma` | X11 / Wayland | KDE Plasma 6 with the Catppuccin KDE colour scheme, window decoration and SDDM login theme. |
| `hyprland` | Wayland | Hyprland + waybar + mako + Rofi + hyprpaper/hypridle. Wayland-only; xrdp is disabled for this profile. |

## Configure

```nix
myDesktop = {
  enable = true;
  profile = "rice";          # xfce | rice | plasma | hyprland
  user = "nixos";
  flavour = "mocha";         # mocha | macchiato | frappe | latte
  accent = "blue";
};
```

Rebuild:

```bash
sudo nixos-rebuild switch
```

The default is `xfce`, so an existing installation keeps its desktop until you
change the profile. `myDesktop.enableDisplayManager = false` is available for
machines that start their session themselves; the OrbStack test VM uses it.

## Themes and dotfiles

- Catppuccin GTK and Kvantum themes, Papirus icons, Catppuccin cursors, Inter
  and JetBrainsMono Nerd Font are installed for every themed profile.
- The X11 rice lives in `desktop/rice/` — i3, polybar, picom, Rofi, dunst,
  xterm colours and the X resources file. The Hyprland setup lives in
  `desktop/hyprland/` — Hyprland, waybar, mako, hyprpaper and hypridle.
- The wallpaper is `desktop/wallpaper.svg`; it is also used by SDDM and the
  Plasma and Hyprland profiles.
- Dotfiles are linked from the Nix store into `~/.config`. Edit the files in
  this repository and rebuild; they are read-only by design.
- On hardware with a DRM device, the rice starts picom's GLX backend for blur
  and rounded corners. The GPU-less OrbStack VM falls back to XRender.

## Rice keybindings

| Keys | Action |
| --- | --- |
| `Super+Return` / `Super+Shift+Return` | xterm / kitty |
| `Super+D` | Rofi application launcher |
| `Super+Tab` | Rofi window switcher |
| `Super+B` / `Super+E` | Firefox / Thunar |
| `Super+Q` | close window |
| `Super+1…0` / `Super+Shift+1…0` | switch / move workspace |
| `Super+R` | resize mode |
| `Super+Escape` | lock |
| `Super+Shift+X` | power menu |
| `Super+Shift+S` | screenshot |
| `Super+Shift+C` / `Super+Shift+R` | reload / restart i3 |

## Remote access

The `xfce`, `rice` and `plasma` profiles work over X11 VNC and xrdp. Hyprland
is Wayland-only, so the module disables xrdp when it is selected; use `rice` or
`plasma` if you need remote X11 access.

## Dedicated host config

For the real host, the repository includes a dedicated wrapper and switch
script, so you can try Hyprland without editing `configuration.nix`:

```bash
./switch-hyprland.sh dry-build   # evaluate/build only
./switch-hyprland.sh switch      # make Hyprland the active session
```

`configuration-hyprland.nix` imports the normal configuration and only forces
`myDesktop.profile = "hyprland"`. The profile is Wayland-only and disables xrdp.
Revert with `sudo nixos-rebuild switch`.

The Hyprland session starts `wayvnc` on `127.0.0.1:5900`, so you can reach it
from another machine without opening a public port:

```bash
ssh -L 5900:127.0.0.1:5900 <user>@<host>
open vnc://127.0.0.1:5900
```

If the host has no monitor, a headless `HEADLESS-VNC` output is created
automatically. VNC is bound to loopback; use the SSH tunnel or Tailscale rather
than exposing port 5900.

The dedicated config also enables SDDM auto-login so the Hyprland session (and
`wayvnc`) starts without a physical login. Remove the
`services.displayManager.autoLogin` block from `configuration-hyprland.nix` if
you prefer to log in manually.

## Try it in OrbStack

The local test VM defaults to the rice and can switch profiles without being
recreated:

```bash
./vm/vm.sh up
./vm/vm.sh vnc
./vm/vm.sh desktop rice      # default
./vm/vm.sh desktop plasma
./vm/vm.sh desktop xfce
```

OrbStack exposes no DRM device, so the VM cannot run a real Hyprland session;
Hyprland's headless/nested backend fails without `/dev/dri`. Use `rice` or
`plasma` in the VM and the dedicated host config above for Hyprland.

The VNC connection password is `nixos`. The same password is set for the `vnc`
Linux user, so Plasma's lock screen and i3lock unlock with `vnc` / `nixos`.

See [Development](../development.md#local-nixos-vm) for the VM details.
