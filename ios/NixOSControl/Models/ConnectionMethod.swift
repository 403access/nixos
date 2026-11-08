import Foundation

/// How the iPhone reaches the NixOS Control API.
enum ConnectionMethod: String, CaseIterable, Identifiable {
    case tailscale
    case wireGuard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tailscale:
            return "Tailscale"
        case .wireGuard:
            return "WireGuard"
        }
    }

    var subtitle: String {
        switch self {
        case .tailscale:
            return "Tailscale Serve with automatic HTTPS"
        case .wireGuard:
            return "FRITZ!Box VPN over your home network"
        }
    }

    var systemImage: String {
        switch self {
        case .tailscale:
            return "network"
        case .wireGuard:
            return "lock.shield"
        }
    }

    var urlPlaceholder: String {
        switch self {
        case .tailscale:
            return "https://nixos.tailnet.ts.net"
        case .wireGuard:
            return "http://192.168.178.10:8787"
        }
    }

    var checklist: [(number: String, text: String)] {
        switch self {
        case .tailscale:
            return [
                (
                    "1",
                    "Install Tailscale on this iPhone and sign in to the same tailnet as your NixOS machine."
                ),
                (
                    "2",
                    "Enable HTTPS certificates for your tailnet in the Tailscale admin console, then run `sudo tailscale up` on the machine."
                ),
                (
                    "3",
                    "Read the token with `sudo nixos-control-token` or `sudo cat /var/lib/nixos-control/token`."
                ),
                (
                    "4",
                    "Enter the machine's Tailscale HTTPS URL above, for example `https://nixos.tailnet-name.ts.net`."
                ),
            ]
        case .wireGuard:
            return [
                (
                    "1",
                    "In the FRITZ!Box, open Internet → Permit Access → VPN (WireGuard) and add a connection for this iPhone."
                ),
                (
                    "2",
                    "Scan the QR code with the WireGuard app and turn the tunnel on. Confirm the iPhone can reach your home network."
                ),
                (
                    "3",
                    "On the NixOS machine, set `address = \"0.0.0.0\"`, `openFirewall = true` and `tailscaleServe.enable = false`, then rebuild and restart nixos-control."
                ),
                (
                    "4",
                    "Read the token with `sudo nixos-control-token` or `sudo cat /var/lib/nixos-control/token`."
                ),
                (
                    "5",
                    "Enter the machine's LAN address above, for example `http://192.168.178.10:8787`."
                ),
            ]
        }
    }

    var footnote: String {
        switch self {
        case .tailscale:
            return "All traffic stays inside your Tailscale network. The API server never listens on the public internet."
        case .wireGuard:
            return "WireGuard encrypts the tunnel between your iPhone and the FRITZ!Box. Inside the tunnel the API uses plain HTTP, so keep port 8787 behind the firewall."
        }
    }

    var settingsHelp: String {
        switch self {
        case .tailscale:
            return "The app connects through your tailnet, so the server does not need an open port. If the connection fails, check that Tailscale is connected on both devices and that HTTPS is enabled for your tailnet."
        case .wireGuard:
            return "Turn on the WireGuard tunnel on this iPhone first, then use the machine's LAN address (for example http://192.168.178.10:8787). The NixOS module must listen on 0.0.0.0, open port 8787 in the firewall and disable Tailscale Serve."
        }
    }
}
