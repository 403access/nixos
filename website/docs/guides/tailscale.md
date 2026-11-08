---
title: Tailscale & security
sidebar_position: 2
description: Expose the API safely with Tailscale Serve and understand the security model.
---

# Tailscale and security

:::tip
Already running WireGuard on a FRITZ!Box? You can use that VPN instead of
Tailscale. See [FRITZ!Box WireGuard](./fritzbox-wireguard.md).
:::

## The security model

The server runs as root because it talks to systemd, reads the journal, manages
ZFS, and invokes `nixos-rebuild`. It is protected by a single bearer token.

:::danger
A leaked token is effectively root access to the machine. Protect it like an SSH
private key.
:::

Defaults that keep the blast radius small:

- The server listens on `127.0.0.1:8787` only.
- Every request requires `Authorization: Bearer <token>`.
- Tokens are 32 random bytes (hex-encoded) and compared in constant time, with a
  small delay on failures.
- No ports are opened on the router or the public interface.
- `allowRebuild` and `allowPower` can be disabled independently.

## Tailscale Serve

Enable MagicDNS and HTTPS certificates for your tailnet in the
[Tailscale admin console](https://login.tailscale.com/admin/dns), then:

```bash
sudo tailscale up
sudo systemctl restart nixos-control-tailscale-serve
sudo tailscale serve status
```

The module runs:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:8787
```

Requests to `https://<machine>.<tailnet>.ts.net` are terminated by Tailscale and
forwarded to loopback. WireGuard encrypts the traffic end to end.

## Restrict who can connect

Use [Tailscale ACLs](https://tailscale.com/kb/1018/acls) so only your phone can
reach port 443 on the server. For example:

```json
{
  "grants": [
    {
      "src": ["autogroup:member"],
      "dst": ["tag:server"],
      "ip": ["443"]
    }
  ],
  "tagOwners": {
    "tag:server": ["autogroup:admin"]
  }
}
```

Tag the NixOS machine with `tag:server`, then narrow `src` to the devices that
should have access.

## Rotate the token

```bash
sudo systemctl stop nixos-control
sudo rm /var/lib/nixos-control/token
sudo systemctl start nixos-control
sudo nixos-control-token
```

Update the token in the app afterwards.

## Hardening checklist

- [ ] Keep `address = "127.0.0.1"` and `openFirewall = false`.
- [ ] Use Tailscale Serve instead of publishing port `8787`.
- [ ] Restrict port 443 with Tailscale ACLs.
- [ ] If you use FRITZ!Box WireGuard instead, open only port `8787` and never
      forward it from the internet.
- [ ] Disable `allowRebuild` and `allowPower` if you do not need them.
- [ ] Take ZFS snapshots or backups before running `switch`.
- [ ] Prefer the `test` rebuild action when validating a configuration.
- [ ] Rotate the token if a device is lost or the token may have leaked.
