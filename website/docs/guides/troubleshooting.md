---
title: Troubleshooting
sidebar_position: 4
description: Fix common authentication, Tailscale, rebuild and data problems.
---

# Troubleshooting

## `401 unauthorized`

The token does not match. Read it again with `sudo nixos-control-token`, then
save it in the app's Settings screen.

## Tailscale Serve fails

HTTPS certificates or MagicDNS are not enabled for the tailnet, or
`tailscale up` has not completed.

```bash
journalctl -u nixos-control-tailscale-serve -e
tailscale serve status
sudo systemctl restart nixos-control-tailscale-serve
```

## The app cannot connect

First check which connection method the app is set to.

**Tailscale:** confirm Tailscale is connected on the phone and on the machine.
Use the MagicDNS HTTPS name, not the LAN IP, when relying on Serve.

**WireGuard:** confirm the tunnel is active, use the machine's LAN address
(`http://<LAN-IP>:8787`), and make sure the server listens on `0.0.0.0` with
port `8787` open in the firewall. See
[FRITZ!Box WireGuard](./fritzbox-wireguard.md).

Also verify the API locally:

```bash
TOKEN=$(sudo nixos-control-token)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8787/api/health
```

## WireGuard connection fails

```bash
ss -ltnp | grep 8787
sudo systemctl status nixos-control
journalctl -u nixos-control -e
```

The listener should be `0.0.0.0:8787` (or `*:8787`) for VPN access. Rebuild the
configuration and restart `nixos-control` after changing `address`,
`openFirewall` or `tailscaleServe.enable`. If Safari on the phone gets a `401`,
the network path works and only the token is wrong.

## A rebuild fails

The job output is shown in the System tab. For channel-based systems,
`NIX_PATH` is passed through from `config.nix.nixPath`; for flakes, set
`services.nixos-control.flake`.

Try `dry-activate` or `test` first:

- `test` activates the configuration without making it the boot default.
- `dry-activate` shows what would change without activating.

## No ZFS data

Confirm `zpool` and `zfs` are on the system path and the pool is imported:

```bash
zpool status
zfs list
```

## Logs are empty

The server reads the journal as root. Check for server-side errors:

```bash
journalctl -u nixos-control -e
```

## Check service status

```bash
systemctl status nixos-control nixos-control-tailscale-serve
```

## Reset the token

```bash
sudo systemctl stop nixos-control
sudo rm /var/lib/nixos-control/token
sudo systemctl start nixos-control
sudo nixos-control-token
```

Then update the token in the app.

## The app still shows stale data

Status is polled, not streamed. Pull to refresh or reopen the tab. Rebuild jobs
are held in memory and disappear if the server restarts.
