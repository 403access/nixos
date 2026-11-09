---
title: Configuration
sidebar_position: 1
description: All services.nixos-control options and example configurations.
---

# Configuration

The NixOS module installs the server, generates the token file, and runs two
systemd units: the API server and an optional Tailscale Serve proxy.

## Options

| Option | Default | Description |
| --- | --- | --- |
| `services.nixos-control.enable` | `false` | Enable the API server |
| `address` | `127.0.0.1` | Listen address |
| `port` | `8787` | Listen port |
| `openFirewall` | `false` | Open the port in the firewall on all interfaces |
| `tokenFile` | `/var/lib/nixos-control/token` | Bearer-token file, generated if missing |
| `flake` | `null` | When set, rebuilds use `--flake <value>` |
| `allowRebuild` | `true` | Allow `nixos-rebuild` actions |
| `allowPower` | `true` | Allow reboot/shutdown |
| `tailscaleServe.enable` | `true` | Expose the API via Tailscale Serve |
| `tailscaleServe.httpsPort` | `443` | HTTPS port used by Tailscale Serve |

## Read-only mode

If you only want monitoring:

```nix
services.nixos-control = {
  enable = true;
  allowRebuild = false;
  allowPower = false;
};
```

The app reads these capabilities from `/api/status` and hides the corresponding
actions.

## LAN and WireGuard mode

To skip Tailscale entirely on a trusted network, or to use the WireGuard VPN
that already runs on your FRITZ!Box:

```nix
services.nixos-control = {
  address = "0.0.0.0";
  openFirewall = true;
  tailscaleServe.enable = false;
};
```

Rebuild and restart the server so the new listen address takes effect:

```bash
sudo nixos-rebuild switch
sudo systemctl restart nixos-control
```

The phone can then use `http://<LAN-IP>:8787`. The app offers both **Tailscale**
and **WireGuard** presets during setup. For the FRITZ!Box walkthrough, see
[FRITZ!Box WireGuard](./fritzbox-wireguard.md).

:::warning
This mode is plain HTTP. WireGuard encrypts the path from the phone to the
FRITZ!Box, but a direct LAN connection is unencrypted. Do not use either on
untrusted networks, and never expose port `8787` directly to the internet.

`openFirewall` opens the port on every interface. If the host has a publicly
routable IPv6 address, bind to the LAN address and open the port only on the
LAN interface instead:

```nix
services.nixos-control.address = "192.168.178.10";
networking.firewall.interfaces."enp1s0".allowedTCPPorts = [ 8787 ];
```
:::

## Custom token location

```nix
services.nixos-control.tokenFile = "/run/secrets/nixos-control-token";
```

The file must be readable by the root-owned service. If it does not exist, the
service generates a new 32-byte token on start.

## Rebuild flake

If your system is flake-based, pass the flake reference so rebuild actions use
`--flake`:

```nix
services.nixos-control.flake = "/etc/nixos#nixos";
```

See [Flakes](./flakes.md) for details.

## Units

| Unit | Purpose |
| --- | --- |
| `nixos-control` | The Rust API server |
| `nixos-control-tailscale-serve` | `tailscale serve` proxy (optional) |

Check them with:

```bash
systemctl status nixos-control nixos-control-tailscale-serve
journalctl -u nixos-control -e
```
