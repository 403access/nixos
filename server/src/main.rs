use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use clap::{ArgAction, Parser};

use nixos_control::activity::ActivityStore;
use nixos_control::api::{build_router, AppState};
use nixos_control::config::AppConfig;
use nixos_control::history::{StatusHistory, DEFAULT_HISTORY_CAPACITY};
use nixos_control::jobs::JobManager;
use nixos_control::peripherals::LocalPeripherals;
use nixos_control::system::{LocalSystem, SystemProbe};
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

    /// JSONL file that keeps the action audit trail across restarts. Optional.
    #[arg(long)]
    activity_file: Option<PathBuf>,
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
    let mut config = AppConfig::new(token_file, flake, args.allow_rebuild, args.allow_power);
    config.activity_file = args.activity_file;

    let system: Arc<dyn SystemProbe> = Arc::new(LocalSystem::new(&config, VERSION));
    let sampler_system = system.clone();
    let jobs = Arc::new(JobManager::new());
    let peripherals = Arc::new(LocalPeripherals::new());
    let activity = Arc::new(ActivityStore::new(config.activity_file.clone()));
    let history = Arc::new(StatusHistory::new(DEFAULT_HISTORY_CAPACITY));
    let sampler_history = history.clone();
    let state = AppState {
        config,
        system,
        jobs,
        peripherals,
        activity,
        history,
        version: VERSION.to_string(),
    };
    let app = build_router(state);

    // Keep a rolling six-hour history for the dashboard charts.
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(10));
        loop {
            interval.tick().await;
            let system = sampler_system.clone();
            match tokio::task::spawn_blocking(move || system.collect_status()).await {
                Ok(status) => {
                    sampler_history.record(&status);
                }
                Err(error) => log::warn!("status history sampler failed: {error}"),
            }
        }
    });

    let listener = match tokio::net::TcpListener::bind(&args.listen).await {
        Ok(listener) => listener,
        Err(error) => {
            log::error!("could not listen on {}: {error}", args.listen);
            std::process::exit(1);
        }
    };

    log::info!("nixos-control {} listening on {}", VERSION, args.listen);
    if let Err(error) = axum::serve(
        listener,
        app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .await
    {
        log::error!("server error: {error}");
        std::process::exit(1);
    }
}
