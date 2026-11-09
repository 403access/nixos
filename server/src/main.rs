use std::path::PathBuf;
use std::sync::Arc;

use clap::{ArgAction, Parser};

use nixos_control::api::{build_router, AppState};
use nixos_control::config::AppConfig;
use nixos_control::jobs::JobManager;
use nixos_control::system::LocalSystem;
use nixos_control::VERSION;

#[derive(Debug, Parser)]
#[command(
    name = "nixos-control",
    version = VERSION,
    about = "Small authenticated API for monitoring and managing a NixOS machine"
)]
struct Args {
    /// Address to listen on.
    #[arg(long, default_value = "127.0.0.1:8787")]
    listen: String,

    /// File containing the bearer token.
    #[arg(long)]
    token_file: Option<PathBuf>,

    /// Optional flake reference for nixos-rebuild (for example /etc/nixos#hostname).
    #[arg(long, default_value = "")]
    flake: String,

    /// Allow nixos-rebuild actions.
    #[arg(long, default_value_t = true, action = ArgAction::Set)]
    allow_rebuild: bool,

    /// Allow reboot and shutdown actions.
    #[arg(long, default_value_t = true, action = ArgAction::Set)]
    allow_power: bool,
}

#[tokio::main]
async fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let args = Args::parse();
    let Some(token_file) = args.token_file else {
        log::error!("--token-file is required");
        std::process::exit(1);
    };

    let flake = if args.flake.is_empty() {
        None
    } else {
        Some(args.flake)
    };
    let config = AppConfig::new(token_file, flake, args.allow_rebuild, args.allow_power);

    let system = Arc::new(LocalSystem::new(&config, VERSION));
    let jobs = Arc::new(JobManager::new());
    let state = AppState {
        config,
        system,
        jobs,
        version: VERSION.to_string(),
    };
    let app = build_router(state);

    let listener = match tokio::net::TcpListener::bind(&args.listen).await {
        Ok(listener) => listener,
        Err(error) => {
            log::error!("could not listen on {}: {error}", args.listen);
            std::process::exit(1);
        }
    };

    log::info!("nixos-control {} listening on {}", VERSION, args.listen);
    if let Err(error) = axum::serve(listener, app).await {
        log::error!("server error: {error}");
        std::process::exit(1);
    }
}
