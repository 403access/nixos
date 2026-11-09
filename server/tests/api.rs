use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use axum::body::Body;
use axum::http::{HeaderMap, Method, Request, StatusCode};
use axum::Router;
use http_body_util::BodyExt;
use nixos_control::api::{build_router, AppState};
use nixos_control::config::AppConfig;
use nixos_control::jobs::{Job, JobLauncher};
use nixos_control::models::{
    CpuInfo, DatasetInfo, FilesystemInfo, Generation, PoolInfo, ServiceUnit, Status,
    StorageSnapshot,
};
use nixos_control::system::SystemProbe;
use tempfile::TempDir;
use tower::ServiceExt;

#[derive(Debug, Clone, PartialEq)]
struct StartedJob {
    kind: String,
    program: String,
    args: Vec<String>,
    dir: Option<PathBuf>,
}

#[derive(Clone, Default)]
struct FakeJobs {
    jobs: Arc<Mutex<Vec<Job>>>,
    started: Arc<Mutex<Vec<StartedJob>>>,
}

impl FakeJobs {
    fn started(&self) -> Vec<StartedJob> {
        self.started.lock().unwrap().clone()
    }
}

impl JobLauncher for FakeJobs {
    fn start(&self, kind: &str, program: &str, args: Vec<String>, dir: Option<PathBuf>) -> Job {
        let mut jobs = self.jobs.lock().unwrap();
        let job = Job {
            id: format!("job-{}", jobs.len() + 1),
            kind: kind.to_string(),
            status: "running".to_string(),
            started_at: "2026-01-01T00:00:00Z".to_string(),
            finished_at: None,
            exit_code: None,
            output: String::new(),
            error: None,
        };
        jobs.push(job.clone());
        self.started.lock().unwrap().push(StartedJob {
            kind: kind.to_string(),
            program: program.to_string(),
            args,
            dir,
        });
        job
    }

    fn snapshot(&self, id: &str) -> Option<Job> {
        self.jobs
            .lock()
            .unwrap()
            .iter()
            .find(|job| job.id == id)
            .cloned()
    }

    fn cancel(&self, id: &str) -> Option<Job> {
        let mut jobs = self.jobs.lock().unwrap();
        let job = jobs.iter_mut().find(|job| job.id == id)?;
        job.status = "cancelled".to_string();
        job.error = Some("cancelled".to_string());
        Some(job.clone())
    }

    fn list(&self) -> Vec<Job> {
        self.jobs.lock().unwrap().clone()
    }
}

#[derive(Clone, Default)]
struct MockSystem {
    calls: Arc<Mutex<Vec<String>>>,
    action_error: Option<String>,
    logs_error: Option<String>,
}

impl MockSystem {
    fn record(&self, call: impl Into<String>) {
        self.calls.lock().unwrap().push(call.into());
    }

    fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
}

impl SystemProbe for MockSystem {
    fn collect_status(&self) -> Status {
        let mut status = empty_status();
        status.server_version = "test-version".to_string();
        status.hostname = "fixture-host".to_string();
        status.os = "NixOS 25.05 (Xantusia)".to_string();
        status.nixos_version = "25.05".to_string();
        status.generation = 12;
        status.capabilities.rebuild = true;
        status.capabilities.power = true;
        status
    }

    fn collect_services(&self) -> Vec<ServiceUnit> {
        vec![ServiceUnit {
            unit: "nginx.service".to_string(),
            load: "loaded".to_string(),
            active: "active".to_string(),
            sub: "running".to_string(),
            description: "Web server".to_string(),
        }]
    }

    fn collect_storage(&self) -> StorageSnapshot {
        StorageSnapshot {
            pools: vec![PoolInfo {
                name: "tank".to_string(),
                size: 1000,
                allocated: 400,
                free: 600,
                health: "ONLINE".to_string(),
                fragmentation: "5".to_string(),
            }],
            datasets: vec![DatasetInfo {
                name: "tank/data".to_string(),
                used: 10,
                available: 600,
                refer: 10,
                mountpoint: "/tank/data".to_string(),
            }],
            filesystems: vec![FilesystemInfo {
                source: "/dev/sda1".to_string(),
                fstype: "ext4".to_string(),
                size: 1000,
                used: 400,
                available: 600,
                use_percent: 40.0,
                mountpoint: "/".to_string(),
            }],
        }
    }

    fn collect_generations(&self) -> Vec<Generation> {
        vec![Generation {
            number: 12,
            date: "2026-01-01 00:00:00".to_string(),
            current: true,
        }]
    }

    fn service_action(&self, unit: &str, action: &str) -> Result<(), String> {
        self.record(format!("{action} {unit}"));
        match &self.action_error {
            Some(error) => Err(error.clone()),
            None => Ok(()),
        }
    }

    fn service_logs(&self, unit: &str, lines: usize) -> Result<Vec<String>, String> {
        self.record(format!("logs {unit} {lines}"));
        match &self.logs_error {
            Some(error) => Err(error.clone()),
            None => Ok(vec![
                "2026-01-01 line one".to_string(),
                "2026-01-01 line two".to_string(),
            ]),
        }
    }

    fn system_logs(&self, lines: usize) -> Result<Vec<String>, String> {
        self.record(format!("system logs {lines}"));
        Ok(vec!["system line".to_string()])
    }

    fn pool_status(&self, name: &str) -> Result<String, String> {
        self.record(format!("pool {name}"));
        Ok("pool is healthy".to_string())
    }

    fn power(&self, action: &str) -> Result<(), String> {
        self.record(format!("power {action}"));
        Ok(())
    }
}

struct Fixture {
    _directory: TempDir,
    state: AppState,
    system: MockSystem,
    jobs: FakeJobs,
}

fn fixture() -> Fixture {
    fixture_with(|config| {
        config.allow_rebuild = true;
        config.allow_power = true;
    })
}

fn fixture_with(configure: impl FnOnce(&mut AppConfig)) -> Fixture {
    let directory = tempfile::tempdir().expect("tempdir");
    let token = directory.path().join("token");
    std::fs::write(&token, "secret\n").unwrap();

    let system = MockSystem::default();
    let jobs = FakeJobs::default();
    let mut config = AppConfig::new(token, None, true, true);
    configure(&mut config);

    Fixture {
        _directory: directory,
        state: AppState {
            config,
            system: Arc::new(system.clone()),
            jobs: Arc::new(jobs.clone()),
            version: "test-version".to_string(),
        },
        system,
        jobs,
    }
}

async fn send(
    app: Router,
    method: Method,
    uri: &str,
    token: Option<&str>,
    body: Option<&str>,
) -> (StatusCode, HeaderMap, String) {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header("Authorization", format!("Bearer {token}"));
    }
    let body = body
        .map(|value| Body::from(value.to_string()))
        .unwrap_or_else(Body::empty);
    let response = app
        .oneshot(builder.body(body).expect("request"))
        .await
        .expect("response");
    let status = response.status();
    let headers = response.headers().clone();
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("body")
        .to_bytes();
    (
        status,
        headers,
        String::from_utf8(bytes.to_vec()).expect("utf8 body"),
    )
}

async fn get(fixture: &Fixture, uri: &str) -> (StatusCode, HeaderMap, String) {
    send(
        build_router(fixture.state.clone()),
        Method::GET,
        uri,
        Some("secret"),
        None,
    )
    .await
}

async fn post(fixture: &Fixture, uri: &str, body: Option<&str>) -> (StatusCode, HeaderMap, String) {
    send(
        build_router(fixture.state.clone()),
        Method::POST,
        uri,
        Some("secret"),
        body,
    )
    .await
}

fn json(body: &str) -> serde_json::Value {
    serde_json::from_str(body).expect("valid JSON")
}

fn empty_status() -> Status {
    Status {
        server_version: "dev".to_string(),
        hostname: "test".to_string(),
        os: String::new(),
        kernel: String::new(),
        nixos_version: String::new(),
        uptime_seconds: 0,
        boot_time: String::new(),
        load: vec![0.0, 0.0, 0.0],
        cpu: CpuInfo {
            model: "Unknown CPU".to_string(),
            cores: 1,
            usage_percent: 0.0,
        },
        memory: Default::default(),
        root_disk: Default::default(),
        pools: Vec::new(),
        temperatures: Vec::new(),
        addresses: Vec::new(),
        generation: 0,
        tailscale: None,
        services: Default::default(),
        capabilities: Default::default(),
    }
}

#[tokio::test]
async fn health_requires_a_bearer_token() {
    let fixture = fixture();
    let (status, headers, body) = send(
        build_router(fixture.state.clone()),
        Method::GET,
        "/api/health",
        None,
        None,
    )
    .await;

    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(
        headers
            .get("WWW-Authenticate")
            .and_then(|value| value.to_str().ok()),
        Some("Bearer realm=\"nixos-control\"")
    );
    assert_eq!(json(&body)["error"], "unauthorized");
}

#[tokio::test]
async fn health_rejects_a_wrong_token() {
    let fixture = fixture();
    let (status, _, _) = send(
        build_router(fixture.state.clone()),
        Method::GET,
        "/api/health",
        Some("wrong"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn health_rejects_non_bearer_authorization() {
    let fixture = fixture();
    let request = Request::builder()
        .method(Method::GET)
        .uri("/api/health")
        .header("Authorization", "Basic abc")
        .body(Body::empty())
        .unwrap();
    let response = build_router(fixture.state.clone())
        .oneshot(request)
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn health_succeeds_with_the_token() {
    let fixture = fixture();
    let (status, _, body) = get(&fixture, "/api/health").await;
    assert_eq!(status, StatusCode::OK);
    let value = json(&body);
    assert_eq!(value["ok"], true);
    assert_eq!(value["version"], "test-version");
    assert!(value["hostname"]
        .as_str()
        .is_some_and(|value| !value.is_empty()));
    assert!(value["time"]
        .as_str()
        .is_some_and(|value| value.ends_with('Z')));
}

#[tokio::test]
async fn missing_token_file_returns_service_unavailable() {
    let mut fixture = fixture();
    fixture.state.config.token_file = fixture._directory.path().join("missing");
    let (status, _, body) = get(&fixture, "/api/health").await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(json(&body)["error"], "API token is not available");
}

#[tokio::test]
async fn security_headers_are_present_on_success_and_failure() {
    let fixture = fixture();
    let (_, headers, _) = get(&fixture, "/api/health").await;
    assert_eq!(headers.get("X-Content-Type-Options").unwrap(), "nosniff");
    assert_eq!(headers.get("X-Frame-Options").unwrap(), "DENY");
    assert_eq!(headers.get("Cache-Control").unwrap(), "no-store");

    let (_, headers, _) = send(
        build_router(fixture.state.clone()),
        Method::GET,
        "/api/health",
        None,
        None,
    )
    .await;
    assert_eq!(headers.get("X-Content-Type-Options").unwrap(), "nosniff");
    assert_eq!(headers.get("Cache-Control").unwrap(), "no-store");
}

#[tokio::test]
async fn unknown_routes_return_not_found() {
    let fixture = fixture();
    let (status, _, body) = get(&fixture, "/api/nope").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body, "404 page not found\n");
}

#[tokio::test]
async fn status_returns_the_system_snapshot() {
    let fixture = fixture();
    let (status, _, body) = get(&fixture, "/api/status").await;
    assert_eq!(status, StatusCode::OK);
    let value = json(&body);
    assert_eq!(value["server_version"], "test-version");
    assert_eq!(value["hostname"], "fixture-host");
    assert_eq!(value["generation"], 12);
    assert_eq!(value["capabilities"]["rebuild"], true);
    assert!(value.get("tailscale").is_none());
}

#[tokio::test]
async fn services_are_listed() {
    let fixture = fixture();
    let (status, _, body) = get(&fixture, "/api/services").await;
    assert_eq!(status, StatusCode::OK);
    let value = json(&body);
    assert_eq!(value[0]["unit"], "nginx.service");
    assert_eq!(value[0]["active"], "active");
}

#[tokio::test]
async fn service_actions_are_forwarded() {
    let fixture = fixture();
    let (status, _, body) = post(&fixture, "/api/services/nginx.service/restart", None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(json(&body)["ok"], true);
    assert_eq!(fixture.system.calls(), vec!["restart nginx.service"]);
}

#[tokio::test]
async fn service_actions_reject_invalid_units_and_actions() {
    let fixture = fixture();
    let (status, _, body) = post(&fixture, "/api/services/nginx/restart", None).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(json(&body)["error"], "invalid service unit name");

    let (status, _, body) = post(&fixture, "/api/services/nginx.service/explode", None).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(json(&body)["error"], "unsupported action");
    assert!(fixture.system.calls().is_empty());
}

#[tokio::test]
async fn service_action_failures_are_reported() {
    let fixture = {
        let mut fixture = fixture();
        fixture.state.system = Arc::new(MockSystem {
            action_error: Some("unit is masked".to_string()),
            ..MockSystem::default()
        });
        fixture
    };
    let (status, _, body) = post(&fixture, "/api/services/nginx.service/start", None).await;
    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(json(&body)["error"], "unit is masked");
}

#[tokio::test]
async fn service_logs_use_the_default_line_count() {
    let fixture = fixture();
    let (status, _, body) = get(&fixture, "/api/services/nginx.service/logs").await;
    assert_eq!(status, StatusCode::OK);
    let value = json(&body);
    assert_eq!(value["unit"], "nginx.service");
    assert_eq!(value["lines"][0], "2026-01-01 line one");
    assert_eq!(fixture.system.calls(), vec!["logs nginx.service 200"]);
}

#[tokio::test]
async fn service_logs_clamp_the_line_count() {
    let fixture = fixture();
    let _ = get(&fixture, "/api/services/nginx.service/logs?lines=1").await;
    let _ = get(&fixture, "/api/services/nginx.service/logs?lines=99999").await;
    let _ = get(&fixture, "/api/services/nginx.service/logs?lines=nope").await;
    assert_eq!(
        fixture.system.calls(),
        vec![
            "logs nginx.service 10",
            "logs nginx.service 2000",
            "logs nginx.service 200"
        ]
    );
}

#[tokio::test]
async fn service_logs_report_command_failures() {
    let fixture = {
        let mut fixture = fixture();
        fixture.state.system = Arc::new(MockSystem {
            logs_error: Some("journal unavailable".to_string()),
            ..MockSystem::default()
        });
        fixture
    };
    let (status, _, body) = get(&fixture, "/api/services/nginx.service/logs").await;
    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(json(&body)["error"], "journal unavailable");
}

#[tokio::test]
async fn system_logs_use_the_default_line_count() {
    let fixture = fixture();
    let (status, _, body) = get(&fixture, "/api/logs").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(json(&body)["lines"][0], "system line");
    assert_eq!(fixture.system.calls(), vec!["system logs 300"]);
}

#[tokio::test]
async fn storage_returns_pools_datasets_and_filesystems() {
    let fixture = fixture();
    let (status, _, body) = get(&fixture, "/api/storage").await;
    assert_eq!(status, StatusCode::OK);
    let value = json(&body);
    assert_eq!(value["pools"][0]["name"], "tank");
    assert_eq!(value["datasets"][0]["name"], "tank/data");
    assert_eq!(value["filesystems"][0]["mountpoint"], "/");
}

#[tokio::test]
async fn pool_status_validates_the_name() {
    let fixture = fixture();
    let (status, _, body) = get(&fixture, "/api/storage/pools/tank").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(json(&body)["name"], "tank");
    assert_eq!(json(&body)["status"], "pool is healthy");
    assert_eq!(fixture.system.calls(), vec!["pool tank"]);

    let (status, _, body) = get(&fixture, "/api/storage/pools/-tank").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(json(&body)["error"], "invalid pool name");
}

#[tokio::test]
async fn generations_are_returned() {
    let fixture = fixture();
    let (status, _, body) = get(&fixture, "/api/system/generations").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(json(&body)["generations"][0]["number"], 12);
    assert_eq!(json(&body)["generations"][0]["current"], true);
}

#[tokio::test]
async fn rebuild_can_be_disabled() {
    let fixture = fixture_with(|config| {
        config.allow_rebuild = false;
    });
    let (status, _, body) = post(
        &fixture,
        "/api/system/rebuild",
        Some(r#"{"action":"switch"}"#),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(
        json(&body)["error"],
        "rebuild actions are disabled on this server"
    );
    assert!(fixture.jobs.started().is_empty());
}

#[tokio::test]
async fn rebuild_rejects_invalid_json_and_unknown_fields() {
    let fixture = fixture();
    let (status, _, body) = post(&fixture, "/api/system/rebuild", Some("not json")).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(json(&body)["error"]
        .as_str()
        .unwrap()
        .starts_with("invalid JSON body:"));

    let (status, _, body) = post(
        &fixture,
        "/api/system/rebuild",
        Some(r#"{"action":"switch","extra":true}"#),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(json(&body)["error"]
        .as_str()
        .unwrap()
        .starts_with("invalid JSON body:"));
}

#[tokio::test]
async fn rebuild_rejects_unsupported_actions() {
    let fixture = fixture();
    let (status, _, body) = post(
        &fixture,
        "/api/system/rebuild",
        Some(r#"{"action":"explode"}"#),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        json(&body)["error"],
        "action must be one of switch, boot, test, dry-activate, dry-build"
    );
}

#[tokio::test]
async fn rebuild_starts_a_job_with_flake_and_working_directory() {
    let mut fixture = fixture();
    let nixos_dir = fixture._directory.path().join("etc-nixos");
    std::fs::create_dir_all(&nixos_dir).unwrap();
    let mut config = fixture.state.config.clone();
    config.flake = Some("/etc/nixos#nixos".to_string());
    config.nixos_dir = nixos_dir.clone();
    fixture.state.config = config;

    let (status, _, body) = post(
        &fixture,
        "/api/system/rebuild",
        Some(r#"{"action":"switch"}"#),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    let value = json(&body);
    assert_eq!(value["status"], "running");
    assert_eq!(value["kind"], "nixos-rebuild switch");

    let started = fixture.jobs.started();
    assert_eq!(started.len(), 1);
    assert_eq!(started[0].program, "nixos-rebuild");
    assert_eq!(
        started[0].args,
        vec![
            "switch".to_string(),
            "--flake".to_string(),
            "/etc/nixos#nixos".to_string()
        ]
    );
    assert_eq!(started[0].dir.as_deref(), Some(nixos_dir.as_path()));
}

#[tokio::test]
async fn rebuild_without_existing_nixos_directory_uses_no_working_directory() {
    let fixture = fixture_with(|config| {
        config.nixos_dir = PathBuf::from("/definitely/not/here");
    });
    let (status, _, _) = post(
        &fixture,
        "/api/system/rebuild",
        Some(r#"{"action":"dry-build"}"#),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(fixture.jobs.started()[0].dir, None);
}

#[tokio::test]
async fn rebuild_request_bodies_are_limited() {
    let fixture = fixture();
    let big = format!(r#"{{"action":"{}"}}"#, "x".repeat(1024 * 1024 + 10));
    let (status, _, _) = post(&fixture, "/api/system/rebuild", Some(&big)).await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
}

#[tokio::test]
async fn power_can_be_disabled() {
    let fixture = fixture_with(|config| {
        config.allow_power = false;
    });
    let (status, _, body) = post(
        &fixture,
        "/api/system/power",
        Some(r#"{"action":"reboot"}"#),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(
        json(&body)["error"],
        "power actions are disabled on this server"
    );
    assert!(fixture.system.calls().is_empty());
}

#[tokio::test]
async fn power_maps_shutdown_and_poweroff_to_poweroff() {
    let fixture = fixture();
    let (status, _, _) = post(
        &fixture,
        "/api/system/power",
        Some(r#"{"action":"shutdown"}"#),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _, _) = post(
        &fixture,
        "/api/system/power",
        Some(r#"{"action":"poweroff"}"#),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _, _) = post(
        &fixture,
        "/api/system/power",
        Some(r#"{"action":"reboot"}"#),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        fixture.system.calls(),
        vec!["power poweroff", "power poweroff", "power reboot"]
    );
}

#[tokio::test]
async fn power_rejects_unknown_actions() {
    let fixture = fixture();
    let (status, _, body) =
        post(&fixture, "/api/system/power", Some(r#"{"action":"sleep"}"#)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        json(&body)["error"],
        "action must be reboot, shutdown or poweroff"
    );
}

#[tokio::test]
async fn job_endpoints_list_look_up_and_cancel() {
    let fixture = fixture();
    let (status, _, body) = get(&fixture, "/api/jobs").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(json(&body), serde_json::json!([]));

    let (status, _, _) = post(
        &fixture,
        "/api/system/rebuild",
        Some(r#"{"action":"test"}"#),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);

    let (status, _, body) = get(&fixture, "/api/jobs").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(json(&body)[0]["id"], "job-1");

    let (status, _, body) = get(&fixture, "/api/jobs/job-1").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(json(&body)["kind"], "nixos-rebuild test");

    let (status, _, body) = post(&fixture, "/api/jobs/job-1/cancel", None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(json(&body)["status"], "cancelled");

    let (status, _, body) = get(&fixture, "/api/jobs/missing").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(json(&body)["error"], "job not found");

    let (status, _, _) = post(&fixture, "/api/jobs/missing/cancel", None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn response_bodies_are_json_with_a_trailing_newline() {
    let fixture = fixture();
    let (_, headers, body) = get(&fixture, "/api/health").await;
    assert_eq!(
        headers.get("Content-Type").unwrap(),
        "application/json; charset=utf-8"
    );
    assert!(body.ends_with('\n'));
}
