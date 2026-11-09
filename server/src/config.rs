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
