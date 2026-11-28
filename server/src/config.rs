use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppConfig {
    pub token_file: PathBuf,
    pub flake: Option<String>,
    pub allow_rebuild: bool,
    pub allow_power: bool,
    /// Directory used as the working directory for `nixos-rebuild` when it
    /// exists. Kept configurable so tests do not depend on the host.
    pub nixos_dir: PathBuf,
    /// Optional JSONL file that receives the action audit trail. When unset the
    /// log stays in memory only.
    pub activity_file: Option<PathBuf>,
    /// JSON file written by the desktop module describing the active theme.
    pub theme_file: PathBuf,
    /// State directory written by `agent-vm`.
    pub sandbox_state: PathBuf,
    /// Runtime directory with sandbox logs and pids.
    pub sandbox_run: PathBuf,
    /// Directory that API-created sandbox workspaces live under.
    pub sandbox_workspaces: PathBuf,
    /// Directory that API-created shared folders live under.
    pub sandbox_shares: PathBuf,
    /// `agent-vm` executable name or absolute path.
    pub agent_vm: String,
    /// Whether sandbox listing and control are enabled.
    pub allow_sandboxes: bool,
}

impl AppConfig {
    pub fn new(
        token_file: impl Into<PathBuf>,
        flake: Option<String>,
        allow_rebuild: bool,
        allow_power: bool,
    ) -> Self {
        Self {
            token_file: token_file.into(),
            flake: flake.filter(|value| !value.is_empty()),
            allow_rebuild,
            allow_power,
            nixos_dir: PathBuf::from("/etc/nixos"),
            activity_file: None,
            theme_file: PathBuf::from("/etc/nixos-control/theme.json"),
            sandbox_state: PathBuf::from("/var/lib/agent-vm"),
            sandbox_run: PathBuf::from("/run/agent-vm"),
            sandbox_workspaces: PathBuf::from("/var/lib/agent-workspaces"),
            sandbox_shares: PathBuf::from("/var/lib/agent-shares"),
            agent_vm: "agent-vm".to_string(),
            allow_sandboxes: true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_flake_is_none() {
        let config = AppConfig::new("/tmp/token", Some(String::new()), true, true);
        assert_eq!(config.flake, None);
    }

    #[test]
    fn non_empty_flake_is_kept() {
        let config = AppConfig::new("/tmp/token", Some("/etc/nixos#nixos".into()), false, true);
        assert_eq!(config.flake.as_deref(), Some("/etc/nixos#nixos"));
        assert!(!config.allow_rebuild);
        assert!(config.allow_power);
    }
}
