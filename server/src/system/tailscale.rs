use std::time::Duration;

use serde::Deserialize;

use crate::commands::CommandRunner;
use crate::models::TailscaleInfo;

#[derive(Debug, Deserialize)]
struct TailscaleStatus {
    #[serde(rename = "BackendState", default)]
    backend_state: String,
    #[serde(rename = "Self", default)]
    this_node: TailscaleSelf,
}

#[derive(Debug, Default, Deserialize)]
struct TailscaleSelf {
    #[serde(rename = "HostName", default)]
    host_name: String,
    #[serde(rename = "DNSName", default)]
    dns_name: String,
    #[serde(rename = "TailscaleIPs", default)]
    tailscale_ips: Vec<String>,
}

pub fn collect_tailscale(runner: &dyn CommandRunner) -> TailscaleInfo {
    if !runner.exists("tailscale") {
        return TailscaleInfo {
            state: "not installed".to_string(),
            ips: Vec::new(),
            ..TailscaleInfo::default()
        };
    }

    let result = runner.run("tailscale", &["status", "--json"], Duration::from_secs(4));
    if result.error.is_some() {
        return TailscaleInfo {
            state: "unavailable".to_string(),
            ips: Vec::new(),
            ..TailscaleInfo::default()
        };
    }

    let Ok(status) = serde_json::from_str::<TailscaleStatus>(&result.output) else {
        return TailscaleInfo {
            state: "unavailable".to_string(),
            ips: Vec::new(),
            ..TailscaleInfo::default()
        };
    };

    TailscaleInfo {
        connected: status.backend_state == "Running",
        hostname: status.this_node.host_name,
        dns_name: status.this_node.dns_name.trim_end_matches('.').to_string(),
        ips: status.this_node.tailscale_ips,
        state: status.backend_state,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::CommandOutput;

    struct TailscaleRunner {
        installed: bool,
        output: CommandOutput,
    }

    impl CommandRunner for TailscaleRunner {
        fn run(&self, _program: &str, _args: &[&str], _timeout: Duration) -> CommandOutput {
            self.output.clone()
        }
        fn exists(&self, _program: &str) -> bool {
            self.installed
        }
    }

    #[test]
    fn reports_not_installed_when_tailscale_is_missing() {
        let runner = TailscaleRunner {
            installed: false,
            output: CommandOutput::failure("", "not found"),
        };
        let info = collect_tailscale(&runner);
        assert_eq!(info.state, "not installed");
        assert!(!info.connected);
        assert!(info.ips.is_empty());
    }

    #[test]
    fn parses_running_tailscale_status() {
        let runner = TailscaleRunner {
            installed: true,
            output: CommandOutput::success(
                r#"{
                    "BackendState": "Running",
                    "Self": {
                        "HostName": "nixos",
                        "DNSName": "nixos.tailnet.ts.net.",
                        "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"]
                    }
                }"#,
            ),
        };
        let info = collect_tailscale(&runner);
        assert!(info.connected);
        assert_eq!(info.hostname, "nixos");
        assert_eq!(info.dns_name, "nixos.tailnet.ts.net");
        assert_eq!(info.ips.len(), 2);
        assert_eq!(info.state, "Running");
    }

    #[test]
    fn invalid_json_reports_unavailable() {
        let runner = TailscaleRunner {
            installed: true,
            output: CommandOutput::success("not json"),
        };
        let info = collect_tailscale(&runner);
        assert_eq!(info.state, "unavailable");
        assert!(!info.connected);
        assert!(info.ips.is_empty());
    }

    #[test]
    fn failed_status_command_reports_unavailable() {
        let runner = TailscaleRunner {
            installed: true,
            output: CommandOutput::failure("", "boom"),
        };
        assert_eq!(collect_tailscale(&runner).state, "unavailable");
    }
}
