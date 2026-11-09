pub mod api;
pub mod commands;
pub mod config;
pub mod jobs;
pub mod models;
pub mod system;
pub mod util;

/// Build-time version. The Nix derivation sets `NIXOS_CONTROL_VERSION`;
/// ordinary cargo builds report `dev`.
pub const VERSION: &str = match option_env!("NIXOS_CONTROL_VERSION") {
    Some(version) => version,
    None => "dev",
};
