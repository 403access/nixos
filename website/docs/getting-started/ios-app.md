---
title: Build the iOS app
sidebar_position: 2
description: Generate, sign and run the SwiftUI iPhone app.
---

# Build the iOS app

Requirements: Xcode 26 or newer,
[XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and iOS 17+.

```bash
cd ios
xcodegen generate
open NixOSControl.xcodeproj
```

In Xcode:

1. Select the **NixOSControl** target → **Signing & Capabilities**.
2. Choose your personal team. Change the bundle identifier if Xcode asks.
3. Connect your iPhone, select it as the run destination, and press **Run**.
4. On the phone, trust the developer certificate if prompted:
   **Settings → General → VPN & Device Management**.

:::note
The AppIcon asset is intentionally empty. Add a 1024×1024 PNG to
`ios/NixOSControl/Resources/Assets.xcassets/AppIcon.appiconset` if you want a
custom home-screen icon.
:::

## Connection methods

The setup screen lets you choose how the phone reaches the server:

| Method | Server URL | Use when |
| --- | --- | --- |
| **Tailscale** | `https://<machine>.<tailnet>.ts.net` | You use Tailscale Serve with automatic HTTPS |
| **WireGuard** | `http://<LAN-IP>:8787` | Your FRITZ!Box already provides a WireGuard VPN |
| **LAN proxy** | `http://<LAN-IP>:3050` | The web dashboard is running on the host and proxies `/api` to loopback |

The LAN proxy option uses the Bun web dashboard as a reverse proxy, so the Rust
API can stay on `127.0.0.1`. It requires the web dashboard from
`peripherals-ui/` to be running on port `3050`; use the same bearer token.

Both choices use the same bearer token and API. The selection is stored in
`UserDefaults`; changing it later in **Settings** does not change the saved URL.
When you enter a bare IP address, a single-label hostname, an mDNS name
(`.local`) or a `.fritz.box` hostname, the app assumes `http://`. Other
hostnames default to `https://`.

For the FRITZ!Box setup, see
[FRITZ!Box WireGuard](../guides/fritzbox-wireguard.md).

## First launch

Enter:

- **Server URL** — the Tailscale or WireGuard address from the table above
  (no trailing slash)
- **API token** — the value from `sudo nixos-control-token`

Tap **Save & Connect**.

The app stores the token in the iOS Keychain. The URL is stored in
`UserDefaults`.

## Peripherals

Open **Dashboard → Peripherals** or **System → Peripherals** to read the Logitech
receiver, its paired devices, battery, signal and firmware. The screen uses the
same server URL and token as the rest of the app and is read-only.

The Apple Magic Keyboard does not appear there: it is not a Logitech device and
the receiver cannot enroll it. See
[Peripherals](../guides/peripherals.md) for details.

## Sessions

Open the **Sessions** tab to see what happened on the machine. The list combines
actions taken through the web console and this app (service start/stop/restart,
rebuilds, power changes) with the host's current console, SSH and RDP logins.
Each entry shows its start time, status and action count; open one to read the
individual actions, rebuild output, session journal and recent shell history.

## Other LAN access

WireGuard mode uses the same server settings as direct LAN access. Enable them
with:

```nix
services.nixos-control = {
  address = "0.0.0.0";
  openFirewall = true;
  tailscaleServe.enable = false;
};
```

Then connect to `http://<LAN-IP>:8787`. Traffic is unencrypted unless it travels
through a VPN such as FRITZ!Box WireGuard, so use it only on a trusted network.
The app allows plain HTTP (`NSAllowsArbitraryLoads`) to support this; Tailscale
HTTPS remains the recommended path when you are away from home without a VPN.

## Simulator fixtures

In `DEBUG` builds, these environment variables can point the app at a local
fixture server:

- `NIXOS_CONTROL_SERVER`
- `NIXOS_CONTROL_TOKEN`
- `NIXOS_CONTROL_TAB` (`dashboard`, `services`, `storage`, `system`, `settings`)

They are ignored in release builds.

To point the simulator at a real server instead, the repository includes a
throwaway NixOS machine for OrbStack:

```bash
./vm/vm.sh ios services
```

See [Local NixOS VM](../development.md#local-nixos-vm) for details.

```bash
cd ios
xcodebuild -project NixOSControl.xcodeproj \
  -scheme NixOSControl \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
```
