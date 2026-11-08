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

## First launch

Enter:

- **Server URL** — `https://<machine>.<tailnet>.ts.net` (no trailing slash)
- **API token** — the value from `sudo nixos-control-token`

Tap **Save & Connect**.

The app stores the token in the iOS Keychain. The URL is stored in
`UserDefaults`.

## Local/LAN testing

For testing without Tailscale, set:

```nix
services.nixos-control = {
  address = "0.0.0.0";
  openFirewall = true;
  tailscaleServe.enable = false;
};
```

Then connect to `http://<LAN-IP>:8787`. This traffic is unencrypted; use it only
on a trusted network. The app allows plain HTTP (`NSAllowsArbitraryLoads`) to
support this; Tailscale HTTPS remains the recommended path.

## Simulator fixtures

In `DEBUG` builds, these environment variables can point the app at a local
fixture server:

- `NIXOS_CONTROL_SERVER`
- `NIXOS_CONTROL_TOKEN`
- `NIXOS_CONTROL_TAB` (`dashboard`, `services`, `storage`, `system`, `settings`)

They are ignored in release builds.

```bash
cd ios
xcodebuild -project NixOSControl.xcodeproj \
  -scheme NixOSControl \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
```
