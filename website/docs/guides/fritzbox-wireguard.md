---
title: FRITZ!Box WireGuard
sidebar_position: 3
description: Use an existing FRITZ!Box WireGuard VPN instead of Tailscale to reach the API from your iPhone.
---

# FRITZ!Box WireGuard

If your FRITZ!Box already provides a WireGuard VPN, you can use it as the
connection between the iPhone app and the NixOS machine. The FRITZ!Box is the
VPN server; the NixOS module only has to accept connections from the home
network.

This is a good fit when:

- You already use the FRITZ!Box WireGuard VPN on your phone.
- You do not want to run Tailscale on the NixOS host.
- You accept that the API uses plain HTTP inside the encrypted VPN tunnel.

:::note
The Go server is unchanged. The app simply selects **WireGuard** in its setup
screen and connects to the machine's LAN address.
:::

## 1. Create a WireGuard connection in the FRITZ!Box

1. Open the FRITZ!Box user interface.
2. Go to **Internet → Permit Access → VPN (WireGuard)**.
3. Click **Add Connection** and choose the option to connect a single device
   (smartphone or tablet).
4. Give the connection a name, for example `iPhone`.
5. Scan the QR code with the official [WireGuard app](https://www.wireguard.com/install/)
   on your iPhone. Alternatively, download the configuration file and import it.
6. Turn the tunnel on and confirm that the iPhone can reach your home network.

Tip: assign the NixOS machine a fixed DHCP address in the FRITZ!Box, or use a
stable hostname such as `nixos.fritz.box`. The app needs an address that does
not change.

## 2. Let the API listen on the LAN

By default the server binds to `127.0.0.1` and is exposed through Tailscale
Serve. For WireGuard, listen on all interfaces, open the API port and turn
Tailscale Serve off:

```nix
services.nixos-control = {
  enable = true;
  address = "0.0.0.0";
  openFirewall = true;
  tailscaleServe.enable = false;
};
```

Rebuild:

```bash
sudo nixos-rebuild switch
```

Because the module deliberately does not restart the server during a rebuild,
apply the new listen address manually:

```bash
sudo systemctl restart nixos-control
```

You do **not** need to configure WireGuard on the NixOS machine. The FRITZ!Box
terminates the VPN; traffic arrives from the router over the normal LAN
interface.

## 3. Verify the API

On the NixOS machine:

```bash
TOKEN=$(sudo nixos-control-token)
ss -ltnp | grep 8787
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8787/api/health
```

With the WireGuard tunnel active on another device, replace `127.0.0.1` with the
machine's LAN address:

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://192.168.178.10:8787/api/health
```

You should see `{"ok":true,"version":"0.1.0",...}`.

## 4. Configure the iPhone app

On the setup screen:

1. Select **WireGuard** as the connection method.
2. Enter the machine's LAN address, for example
   `http://192.168.178.10:8787` (no trailing slash).
3. Paste the token from `sudo nixos-control-token`.
4. Tap **Save & Connect**.

The URL is stored in `UserDefaults` and the token in the iOS Keychain. You can
switch between Tailscale and WireGuard later in **Settings**; the method is only
guidance, so changing it does not change the saved URL.

## Security

- WireGuard encrypts traffic between the iPhone and the FRITZ!Box. Inside the
  tunnel and on the LAN, the API uses plain HTTP.
- Every request still requires the bearer token. Anyone who can reach port
  `8787` and knows the token has root-equivalent control of the machine.
- Do not create a port forward or an exposed host for port `8787`. The VPN is
  the only way in from outside.
- `openFirewall` opens TCP `8787` on **all** interfaces. If the host has a
  publicly routable IPv6 address or joins untrusted networks, bind to the LAN
  address and scope the rule to the LAN interface instead:

  ```nix
  services.nixos-control = {
    address = "192.168.178.10"; # fixed DHCP lease
    openFirewall = false;
    tailscaleServe.enable = false;
  };
  networking.firewall.interfaces."enp1s0".allowedTCPPorts = [ 8787 ];
  ```

  Replace `enp1s0` with the interface name from `ip link`.
- If you do not need actions, set `allowRebuild = false` and
  `allowPower = false`.
- To go back to Tailscale, restore `address = "127.0.0.1"`,
  `openFirewall = false` and `tailscaleServe.enable = true`, rebuild, and
  restart the service.

## Troubleshooting

**The app cannot connect over WireGuard**

1. Confirm the tunnel is active in the WireGuard app.
2. Open `http://<LAN-IP>:8787/api/health` in Safari on the phone. A `401` means
   the server is reachable and only the token is missing.
3. Check that the server listens on all interfaces:
   `ss -ltnp | grep 8787` should show `0.0.0.0:8787` or `*:8787`.
4. Check the firewall rule and restart the service after rebuilding.
5. Check `journalctl -u nixos-control -e` for server-side errors.

**The connection works on the LAN but not through the VPN**

Check the FRITZ!Box WireGuard connection and make sure the VPN routes the home
network (`192.168.178.0/24` by default). Also confirm the phone is not using a
different address for the machine.
