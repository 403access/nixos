use std::net::IpAddr;

use nix::ifaddrs::getifaddrs;
use nix::net::if_::InterfaceFlags;

/// Enumerate non-loopback, non-link-local addresses on interfaces that are up.
/// IPv4 addresses are sorted before IPv6 addresses, matching the Go server.
pub fn collect_addresses() -> Vec<String> {
    let mut addresses = Vec::new();
    let Ok(interfaces) = getifaddrs() else {
        return addresses;
    };

    for interface in interfaces {
        if !interface.flags.contains(InterfaceFlags::IFF_UP)
            || interface.flags.contains(InterfaceFlags::IFF_LOOPBACK)
        {
            continue;
        }

        let Some(address) = interface.address else {
            continue;
        };

        let ip: Option<IpAddr> = if let Some(inet) = address.as_sockaddr_in() {
            Some(IpAddr::V4(inet.ip()))
        } else {
            address.as_sockaddr_in6().map(|inet| IpAddr::V6(inet.ip()))
        };

        let Some(ip) = ip else {
            continue;
        };
        if ip.is_loopback() {
            continue;
        }
        let link_local = match ip {
            IpAddr::V4(ipv4) => ipv4.is_link_local(),
            IpAddr::V6(ipv6) => ipv6.is_unicast_link_local(),
        };
        if link_local {
            continue;
        }
        addresses.push(ip.to_string());
    }

    addresses.sort_by(|left, right| {
        let left_ipv6 = left.contains(':');
        let right_ipv6 = right.contains(':');
        match left_ipv6.cmp(&right_ipv6) {
            std::cmp::Ordering::Equal => left.cmp(right),
            other => other,
        }
    });
    addresses
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collected_addresses_have_no_loopback_or_link_local_entries() {
        for address in collect_addresses() {
            let ip: IpAddr = address.parse().expect("valid IP string");
            assert!(!ip.is_loopback());
            match ip {
                IpAddr::V4(ipv4) => assert!(!ipv4.is_link_local()),
                IpAddr::V6(ipv6) => assert!(!ipv6.is_unicast_link_local()),
            }
        }
    }
}
