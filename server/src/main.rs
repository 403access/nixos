use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use clap::{ArgAction, Parser};

use nixos_control::activity::ActivityStore;
use nixos_control::api::{build_router, AppState};
use nixos_control::config::AppConfig;
use nixos_control::files::{FileBrowser, LocalFiles};
use nixos_control::history::{StatusHistory, DEFAULT_HISTORY_CAPACITY};
use nixos_control::jobs::JobManager;
use nixos_control::peripherals::LocalPeripherals;
use nixos_control::rdp::{LocalRdp, RdpReset};
use nixos_control::resources::{ResourceMonitor, ResourceProbe, SAMPLE_INTERVAL};
use nixos_control::sandboxes::{LocalSandboxes, SandboxProbe};
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

    /// Directory containing `agent-vm` sandbox state.
    #[arg(long, default_value = "/var/lib/agent-vm")]
    sandbox_state: PathBuf,

    /// Directory containing sandbox logs and pid files.
    #[arg(long, default_value = "/run/agent-vm")]
    sandbox_run: PathBuf,

    /// Directory under which API-created sandbox workspaces live.
    #[arg(long, default_value = "/var/lib/agent-workspaces")]
    sandbox_workspaces: PathBuf,

    /// Directory under which API-created shared folders live.
    #[arg(long, default_value = "/var/lib/agent-shares")]
    sandbox_shares: PathBuf,

    /// `agent-vm` executable name or absolute path.
    #[arg(long, default_value = "agent-vm")]
    agent_vm: String,

    /// Allow listing and controlling agent sandboxes.
    #[arg(long, default_value_t = true, action = ArgAction::Set)]
    allow_sandboxes: bool,
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
    config.sandbox_state = args.sandbox_state;
    config.sandbox_run = args.sandbox_run;
    config.sandbox_workspaces = args.sandbox_workspaces;
    config.sandbox_shares = args.sandbox_shares;
    config.agent_vm = args.agent_vm;
    config.allow_sandboxes = args.allow_sandboxes;

    let system: Arc<dyn SystemProbe> = Arc::new(LocalSystem::new(&config, VERSION));
    let sampler_system = system.clone();
    let sandboxes: Arc<dyn SandboxProbe> = Arc::new(LocalSandboxes::new(&config));
    let jobs = Arc::new(JobManager::new());
    let peripherals = Arc::new(LocalPeripherals::new());
    let activity = Arc::new(ActivityStore::new(config.activity_file.clone()));
    let history = Arc::new(StatusHistory::new(DEFAULT_HISTORY_CAPACITY));
    let sampler_history = history.clone();
    let resource_monitor = Arc::new(ResourceMonitor::new());
    let resources: Arc<dyn ResourceProbe> = resource_monitor.clone();
    let rdp: Arc<dyn RdpReset> = Arc::new(LocalRdp::default());
    let files: Arc<dyn FileBrowser> = Arc::new(LocalFiles);
    let state = AppState {
        config,
        system,
        sandboxes,
        jobs,
        peripherals,
        activity,
        history,
        resources,
        rdp,
        files,
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

    // Attribute CPU, memory and disk I/O to processes, services and apps,
    // and network traffic from the sockets each process owns.
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(SAMPLE_INTERVAL);
        loop {
            interval.tick().await;
            let monitor = resource_monitor.clone();
            if let Err(error) = tokio::task::spawn_blocking(move || monitor.sample()).await {
                log::warn!("resource sampler failed: {error}");
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
