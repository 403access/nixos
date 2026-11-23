import type { ServiceUnit } from "./types";

export type ServiceGroup =
  | "NixOS Control"
  | "Bridge"
  | "Virtualization"
  | "Desktop"
  | "Audio"
  | "Network"
  | "Storage"
  | "Containers"
  | "Hardware"
  | "System"
  | "Other";

// Display order of the groups on the Services page.
export const GROUP_ORDER: ServiceGroup[] = [
  "NixOS Control",
  "Bridge",
  "Virtualization",
  "Desktop",
  "Audio",
  "Network",
  "Storage",
  "Containers",
  "Hardware",
  "System",
  "Other",
];

export interface ServiceMeta {
  group: ServiceGroup;
  tags: string[];
}

interface Rule {
  test: RegExp;
  group: ServiceGroup;
  tags: string[];
}

// Unit-name rules, first match wins.
const RULES: Rule[] = [
  { test: /^nixos-control-web/, group: "NixOS Control", tags: ["Web"] },
  { test: /^nixos-control-tailscale/, group: "NixOS Control", tags: ["Tailscale"] },
  { test: /^nixos-control($|\.)/, group: "NixOS Control", tags: ["API"] },

  { test: /^input-leap/, group: "Bridge", tags: ["Input"] },
  { test: /^airpods-audio/, group: "Bridge", tags: ["Audio", "AirPods"] },

  { test: /^(libvirt|virt|qemu|spice)/, group: "Virtualization", tags: ["VM"] },

  { test: /^(lightdm|display-manager)/, group: "Desktop", tags: ["Login"] },
  {
    test: /^(xfce|xfconf|xfwm|xfsettings|xfdesktop|plank|desktop-)/,
    group: "Desktop",
    tags: ["Xfce"],
  },

  { test: /^(pipewire|wireplumber|pulseaudio)/, group: "Audio", tags: ["PipeWire"] },

  { test: /^ssh(d|-session)?($|\.)/, group: "Network", tags: ["SSH"] },
  { test: /^tailscale/, group: "Network", tags: ["VPN"] },
  { test: /^(dhcpcd|dhcpd)/, group: "Network", tags: ["DHCP"] },
  { test: /^(avahi|resolved|nscd)/, group: "Network", tags: ["DNS"] },
  { test: /^(firewall|nftables|iptables)/, group: "Network", tags: ["Firewall"] },
  {
    test: /^(network|wpa_supplicant|NetworkManager|systemd-networkd)/i,
    group: "Network",
    tags: ["Link"],
  },

  { test: /^(zfs|zpool)/, group: "Storage", tags: ["ZFS"] },
  { test: /^(samba|smb|winbind)/, group: "Storage", tags: ["Samba"] },
  { test: /^(udisks|smartd|mount|nfs)/, group: "Storage", tags: ["Disk"] },

  { test: /^(docker|podman|containerd)/, group: "Containers", tags: ["Docker"] },

  { test: /^bluetooth/, group: "Hardware", tags: ["Bluetooth"] },
  { test: /^(upower|thermald|fwupd|power)/, group: "Hardware", tags: ["Power"] },

  {
    test: /^(systemd|dbus|polkit|accounts-daemon|logind|journald|getty)/,
    group: "System",
    tags: ["Core"],
  },
  { test: /^(nix-daemon|nixos-)/, group: "System", tags: ["Nix"] },
];

const DESCRIPTION_HINTS: Array<{ test: RegExp; group: ServiceGroup; tags: string[] }> = [
  { test: /bluetooth/, group: "Hardware", tags: ["Bluetooth"] },
  { test: /virtual machine|libvirt|qemu/, group: "Virtualization", tags: ["VM"] },
  { test: /openssh|ssh server/, group: "Network", tags: ["SSH"] },
  { test: /zfs|zpool/, group: "Storage", tags: ["ZFS"] },
  { test: /samba|smb/, group: "Storage", tags: ["Samba"] },
];

export function serviceMeta(service: ServiceUnit): ServiceMeta {
  const unit = service.unit.replace(/\.service$/, "");

  for (const rule of RULES) {
    if (rule.test.test(unit)) {
      return { group: rule.group, tags: rule.tags };
    }
  }

  const description = `${service.unit} ${service.description}`.toLowerCase();
  for (const hint of DESCRIPTION_HINTS) {
    if (hint.test.test(description)) {
      return { group: hint.group, tags: hint.tags };
    }
  }

  const prefix = unit.split(/[-.@]/)[0];
  return { group: "Other", tags: [prefix || "service"] };
}