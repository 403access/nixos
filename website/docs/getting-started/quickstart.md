---
title: Server quickstart
sidebar_position: 1
description: Install and run the NixOS Control API server on your NixOS machine.
---

# Server quickstart

The server is a stdlib-only Go program packaged with `buildGoModule`, so there
is nothing to install manually on the NixOS machine.

## 1. Add the module

Put this repository at `/etc/nixos` (or copy `configuration.nix`,
`nixos-control.nix`, and the `server/` directory there). The existing config
already contains:

```nix
imports = [
  ./hardware-configuration.nix
  ./nixos-control.nix
];

services.nixos-control.enable = true;

services.tailscale.enable = true;
networking.firewall.trustedInterfaces = [ "tailscale0" ];
```

## 2. Rebuild

```bash
sudo nixos-rebuild switch
```

The first start generates `/var/lib/nixos-control/token`.

## 3. Set up Tailscale

```bash
sudo tailscale up
```

In the [Tailscale admin console](https://login.tailscale.com/admin/dns):

- Enable **MagicDNS**.
- Enable **HTTPS Certificates**.

Then start the Serve unit (it may already be running and retrying):

```bash
sudo systemctl restart nixos-control-tailscale-serve
sudo systemctl status nixos-control nixos-control-tailscale-serve
sudo tailscale serve status
```

The Serve unit runs:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:8787
```

:::tip Using a FRITZ!Box WireGuard VPN?
You can skip Tailscale Serve and use the WireGuard VPN that already runs on your
FRITZ!Box. The server must listen on `0.0.0.0`, open port `8787` and disable
Tailscale Serve. See [FRITZ!Box WireGuard](../guides/fritzbox-wireguard.md).
:::

## 4. Read the API token

```bash
sudo nixos-control-token
# or: sudo cat /var/lib/nixos-control/token
```

## 5. Verify the API

```bash
TOKEN=$(sudo nixos-control-token)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://<machine>.<tailnet>.ts.net/api/health"
```

Use the machine name shown by `tailscale status` and your tailnet's `ts.net`
domain. You should see:

```json
{"ok":true,"version":"0.1.0","hostname":"..."}
```

:::note
`nixos-control` deliberately does not restart itself during
`nixos-rebuild` (so an in-flight rebuild cannot kill its own process). After
changing the server or this module, run
`sudo systemctl restart nixos-control` manually.
:::

## Next

- [Build the iOS app](./ios-app.md)
- [Configuration options](../guides/configuration.md)
- [Tailscale and security](../guides/tailscale.md)
- [FRITZ!Box WireGuard](../guides/fritzbox-wireguard.md)
