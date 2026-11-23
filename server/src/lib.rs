pub mod activity;
pub mod api;
pub mod commands;
pub mod config;
pub mod history;
pub mod jobs;
pub mod models;
pub mod peripherals;
pub mod resources;
pub mod system;
pub mod themes;
pub mod util;

/// Build-time version. The Nix derivation sets `NIXOS_CONTROL_VERSION`;
/// ordinary cargo builds report `dev`.
pub const VERSION: &str = match option_env!("NIXOS_CONTROL_VERSION") {
    Some(version) => version,
    None => "dev",
};
