import Foundation

/// Service grouping and tagging, matching the web console's Services page.
enum ServiceGroup: String, CaseIterable, Identifiable {
    case control = "NixOS Control"
    case bridge = "Bridge"
    case virtualization = "Virtualization"
    case desktop = "Desktop"
    case audio = "Audio"
    case network = "Network"
    case storage = "Storage"
    case containers = "Containers"
    case hardware = "Hardware"
    case system = "System"
    case other = "Other"

    var id: String { rawValue }
}

struct ServiceMeta {
    let group: ServiceGroup
    let tags: [String]
}

enum ServiceGroups {
    private struct Rule {
        let pattern: String
        let group: ServiceGroup
        let tags: [String]
        let caseInsensitive: Bool

        init(_ pattern: String, _ group: ServiceGroup, _ tags: [String], caseInsensitive: Bool = false) {
            self.pattern = pattern
            self.group = group
            self.tags = tags
            self.caseInsensitive = caseInsensitive
        }
    }

    // Unit-name rules, first match wins.
    private static let rules: [Rule] = [
        Rule("^nixos-control-web", .control, ["Web"]),
        Rule("^nixos-control-tailscale", .control, ["Tailscale"]),
        Rule(#"^nixos-control($|\.)"#, .control, ["API"]),

        Rule("^input-leap", .bridge, ["Input"]),
        Rule("^airpods-audio", .bridge, ["Audio", "AirPods"]),

        Rule("^(libvirt|virt|qemu|spice)", .virtualization, ["VM"]),

        Rule("^(lightdm|display-manager)", .desktop, ["Login"]),
        Rule("^(xfce|xfconf|xfwm|xfsettings|xfdesktop|plank|desktop-)", .desktop, ["Xfce"]),

        Rule("^(pipewire|wireplumber|pulseaudio)", .audio, ["PipeWire"]),

        Rule(#"^ssh(d|-session)?($|\.)"#, .network, ["SSH"]),
        Rule("^tailscale", .network, ["VPN"]),
        Rule("^(dhcpcd|dhcpd)", .network, ["DHCP"]),
        Rule("^(avahi|resolved|nscd)", .network, ["DNS"]),
        Rule("^(firewall|nftables|iptables)", .network, ["Firewall"]),
        Rule("^(network|wpa_supplicant|NetworkManager|systemd-networkd)", .network, ["Link"], caseInsensitive: true),

        Rule("^(zfs|zpool)", .storage, ["ZFS"]),
        Rule("^(samba|smb|winbind)", .storage, ["Samba"]),
        Rule("^(udisks|smartd|mount|nfs)", .storage, ["Disk"]),

        Rule("^(docker|podman|containerd)", .containers, ["Docker"]),

        Rule("^bluetooth", .hardware, ["Bluetooth"]),
        Rule("^(upower|thermald|fwupd|power)", .hardware, ["Power"]),

        Rule("^(systemd|dbus|polkit|accounts-daemon|logind|journald|getty)", .system, ["Core"]),
        Rule("^(nix-daemon|nixos-)", .system, ["Nix"]),
    ]

    private static let descriptionHints: [Rule] = [
        Rule("bluetooth", .hardware, ["Bluetooth"], caseInsensitive: true),
        Rule("virtual machine|libvirt|qemu", .virtualization, ["VM"], caseInsensitive: true),
        Rule("openssh|ssh server", .network, ["SSH"], caseInsensitive: true),
        Rule("zfs|zpool", .storage, ["ZFS"], caseInsensitive: true),
        Rule("samba|smb", .storage, ["Samba"], caseInsensitive: true),
    ]

    static func meta(for service: ServiceUnit) -> ServiceMeta {
        let unit = service.unit.hasSuffix(".service")
            ? String(service.unit.dropLast(".service".count))
            : service.unit

        if let match = firstMatch(in: unit, rules: rules) {
            return match
        }

        let description = "\(service.unit) \(service.description)"
        if let match = firstMatch(in: description, rules: descriptionHints) {
            return match
        }

        let prefix = unit.components(separatedBy: CharacterSet(charactersIn: "-.@")).first ?? ""
        return ServiceMeta(group: .other, tags: [prefix.isEmpty ? "service" : prefix])
    }

    private static func firstMatch(in value: String, rules: [Rule]) -> ServiceMeta? {
        for rule in rules {
            var options: String.CompareOptions = [.regularExpression]
            if rule.caseInsensitive {
                options.insert(.caseInsensitive)
            }
            if value.range(of: rule.pattern, options: options) != nil {
                return ServiceMeta(group: rule.group, tags: rule.tags)
            }
        }
        return nil
    }
}

struct GroupedService: Identifiable {
    let service: ServiceUnit
    let meta: ServiceMeta

    var id: String { service.id }
}