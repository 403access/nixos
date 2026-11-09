use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::body::{Body, Bytes};
use axum::extract::{DefaultBodyLimit, Path, Query, Request, State};
use axum::http::{header, HeaderValue, StatusCode};
use axum::middleware::{self, Next};
use axum::response::Response;
use axum::routing::{get, post};
use axum::Router;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use tower_http::catch_panic::CatchPanicLayer;

use crate::config::AppConfig;
use crate::jobs::JobLauncher;
use crate::system::SystemProbe;
use crate::util::{parse_lines_param, valid_pool_name, valid_token, valid_unit_name};

#[derive(Clone)]
pub struct AppState {
    pub config: AppConfig,
    pub system: Arc<dyn SystemProbe>,
    pub jobs: Arc<dyn JobLauncher>,
    pub version: String,
}

pub fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/api/health", get(health))
        .route("/api/status", get(status))
        .route("/api/services", get(service_units))
        .route("/api/services/{unit}/{action}", post(service_action))
        .route("/api/services/{unit}/logs", get(service_logs))
        .route("/api/storage", get(storage))
        .route("/api/storage/pools/{name}", get(pool_status))
        .route("/api/system/generations", get(generations))
        .route("/api/system/rebuild", post(rebuild))
        .route("/api/system/power", post(power))
        .route("/api/logs", get(system_logs))
        .route("/api/jobs", get(jobs))
        .route("/api/jobs/{id}", get(job))
        .route("/api/jobs/{id}/cancel", post(job_cancel))
        .fallback(not_found)
        .with_state(state.clone())
        .layer(DefaultBodyLimit::max(1024 * 1024))
        .layer(middleware::from_fn_with_state(state.clone(), require_auth))
        .layer(middleware::from_fn(security_headers))
        .layer(middleware::from_fn(log_requests))
        .layer(CatchPanicLayer::custom(handle_panic))
}

async fn security_headers(request: Request, next: Next) -> Response {
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers.insert(
        "X-Content-Type-Options",
        HeaderValue::from_static("nosniff"),
    );
    headers.insert("X-Frame-Options", HeaderValue::from_static("DENY"));
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}

async fn require_auth(State(state): State<AppState>, request: Request, next: Next) -> Response {
    let expected = match std::fs::read_to_string(&state.config.token_file) {
        Ok(value) => value.trim().to_string(),
        Err(_) => {
            return error_response(
                StatusCode::SERVICE_UNAVAILABLE,
                "API token is not available",
            )
        }
    };

    let header = request
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok());
    let Some(header) = header else {
        return unauthorized();
    };
    if !header.starts_with("Bearer ") {
        return unauthorized();
    }
    let got = header["Bearer ".len()..].trim();

    if !valid_token(got, &expected) {
        // Slow down brute-force attempts a little, as the Go server does.
        tokio::time::sleep(Duration::from_millis(200)).await;
        return unauthorized();
    }

    next.run(request).await
}

fn unauthorized() -> Response {
    let mut response = error_response(StatusCode::UNAUTHORIZED, "unauthorized");
    response.headers_mut().insert(
        header::WWW_AUTHENTICATE,
        HeaderValue::from_static("Bearer realm=\"nixos-control\""),
    );
    response
}

async fn log_requests(request: Request, next: Next) -> Response {
    let method = request.method().clone();
    let path = request.uri().path().to_string();
    let started = Instant::now();
    let response = next.run(request).await;
    log::info!(
        "{} {} {} {}ms",
        method,
        path,
        response.status().as_u16(),
        started.elapsed().as_millis()
    );
    response
}

fn handle_panic(payload: Box<dyn std::any::Any + Send + 'static>) -> Response {
    let message = if let Some(message) = payload.downcast_ref::<&str>() {
        (*message).to_string()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "unknown panic".to_string()
    };
    log::error!("panic while handling request: {message}");
    error_response(StatusCode::INTERNAL_SERVER_ERROR, "internal server error")
}

pub fn json_response<T: Serialize>(status: StatusCode, value: &T) -> Response {
    let mut body = serde_json::to_vec(value).unwrap_or_else(|_| b"null".to_vec());
    body.push(b'\n');
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json; charset=utf-8")
        .header(header::CACHE_CONTROL, "no-store")
        .body(Body::from(body))
        .expect("valid response")
}

fn error_response(status: StatusCode, message: impl Into<String>) -> Response {
    json_response(status, &serde_json::json!({ "error": message.into() }))
}

async fn blocking<T, F>(work: F) -> Result<T, ()>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    tokio::task::spawn_blocking(work).await.map_err(|_| ())
}

async fn health(State(state): State<AppState>) -> Response {
    let hostname = gethostname::gethostname().to_string_lossy().to_string();
    let time = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    json_response(
        StatusCode::OK,
        &serde_json::json!({
            "ok": true,
            "version": state.version,
            "hostname": hostname,
            "time": time,
        }),
    )
}

async fn status(State(state): State<AppState>) -> Response {
    let system = state.system.clone();
    match blocking(move || system.collect_status()).await {
        Ok(status) => json_response(StatusCode::OK, &status),
        Err(()) => internal_error(),
    }
}

async fn service_units(State(state): State<AppState>) -> Response {
    let system = state.system.clone();
    match blocking(move || system.collect_services()).await {
        Ok(services) => json_response(StatusCode::OK, &services),
        Err(()) => internal_error(),
    }
}

const SERVICE_ACTIONS: [&str; 9] = [
    "start",
    "stop",
    "restart",
    "reload",
    "try-restart",
    "reload-or-restart",
    "enable",
    "disable",
    "reset-failed",
];

async fn service_action(
    State(state): State<AppState>,
    Path((unit, action)): Path<(String, String)>,
) -> Response {
    if !valid_unit_name(&unit) {
        return error_response(StatusCode::BAD_REQUEST, "invalid service unit name");
    }
    if !SERVICE_ACTIONS.contains(&action.as_str()) {
        return error_response(StatusCode::BAD_REQUEST, "unsupported action");
    }

    let system = state.system.clone();
    let result = blocking(move || system.service_action(&unit, &action)).await;
    match result {
        Ok(Ok(())) => json_response(StatusCode::OK, &serde_json::json!({ "ok": true })),
        Ok(Err(message)) => error_response(StatusCode::INTERNAL_SERVER_ERROR, message),
        Err(()) => internal_error(),
    }
}

#[derive(Debug, Default, Deserialize)]
struct LinesQuery {
    lines: Option<String>,
}

async fn service_logs(
    State(state): State<AppState>,
    Path(unit): Path<String>,
    Query(query): Query<LinesQuery>,
) -> Response {
    if !valid_unit_name(&unit) {
        return error_response(StatusCode::BAD_REQUEST, "invalid service unit name");
    }
    let lines = parse_lines_param(query.lines.as_deref().unwrap_or(""), 200);

    let system = state.system.clone();
    let unit_for_call = unit.clone();
    let result = blocking(move || system.service_logs(&unit_for_call, lines)).await;
    match result {
        Ok(Ok(log_lines)) => lines_body(unit, log_lines),
        Ok(Err(message)) => error_response(StatusCode::INTERNAL_SERVER_ERROR, message),
        Err(()) => internal_error(),
    }
}

fn lines_body(unit: String, lines: Vec<String>) -> Response {
    let value = serde_json::json!({
        "unit": unit,
        "lines": lines,
    });
    json_response(StatusCode::OK, &value)
}

async fn system_logs(State(state): State<AppState>, Query(query): Query<LinesQuery>) -> Response {
    let lines = parse_lines_param(query.lines.as_deref().unwrap_or(""), 300);
    let system = state.system.clone();
    match blocking(move || system.system_logs(lines)).await {
        Ok(Ok(log_lines)) => {
            json_response(StatusCode::OK, &serde_json::json!({ "lines": log_lines }))
        }
        Ok(Err(message)) => error_response(StatusCode::INTERNAL_SERVER_ERROR, message),
        Err(()) => internal_error(),
    }
}

async fn storage(State(state): State<AppState>) -> Response {
    let system = state.system.clone();
    match blocking(move || system.collect_storage()).await {
        Ok(storage) => json_response(StatusCode::OK, &storage),
        Err(()) => internal_error(),
    }
}

async fn pool_status(State(state): State<AppState>, Path(name): Path<String>) -> Response {
    if !valid_pool_name(&name) {
        return error_response(StatusCode::BAD_REQUEST, "invalid pool name");
    }

    let system = state.system.clone();
    let pool_name = name.clone();
    match blocking(move || system.pool_status(&pool_name)).await {
        Ok(Ok(status)) => json_response(
            StatusCode::OK,
            &serde_json::json!({ "name": name, "status": status }),
        ),
        Ok(Err(message)) => error_response(StatusCode::INTERNAL_SERVER_ERROR, message),
        Err(()) => internal_error(),
    }
}

async fn generations(State(state): State<AppState>) -> Response {
    let system = state.system.clone();
    match blocking(move || system.collect_generations()).await {
        Ok(generations) => json_response(
            StatusCode::OK,
            &serde_json::json!({ "generations": generations }),
        ),
        Err(()) => internal_error(),
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RebuildRequest {
    action: String,
}

async fn rebuild(State(state): State<AppState>, body: Bytes) -> Response {
    if !state.config.allow_rebuild {
        return error_response(
            StatusCode::FORBIDDEN,
            "rebuild actions are disabled on this server",
        );
    }

    let request: RebuildRequest = match decode_json(body) {
        Ok(request) => request,
        Err(response) => return response,
    };

    match request.action.as_str() {
        "switch" | "boot" | "test" | "dry-activate" | "dry-build" => {}
        _ => {
            return error_response(
                StatusCode::BAD_REQUEST,
                "action must be one of switch, boot, test, dry-activate, dry-build",
            )
        }
    }

    let mut args = vec![request.action.clone()];
    if let Some(flake) = &state.config.flake {
        args.push("--flake".to_string());
        args.push(flake.clone());
    }

    let dir = if state.config.nixos_dir.is_dir() {
        Some(state.config.nixos_dir.clone())
    } else {
        None
    };

    let job = state.jobs.start(
        &format!("nixos-rebuild {}", request.action),
        "nixos-rebuild",
        args,
        dir,
    );
    json_response(StatusCode::ACCEPTED, &job)
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct PowerRequest {
    action: String,
}

async fn power(State(state): State<AppState>, body: Bytes) -> Response {
    if !state.config.allow_power {
        return error_response(
            StatusCode::FORBIDDEN,
            "power actions are disabled on this server",
        );
    }

    let request: PowerRequest = match decode_json(body) {
        Ok(request) => request,
        Err(response) => return response,
    };

    let action = match request.action.as_str() {
        "reboot" => "reboot",
        "shutdown" | "poweroff" => "poweroff",
        _ => {
            return error_response(
                StatusCode::BAD_REQUEST,
                "action must be reboot, shutdown or poweroff",
            )
        }
    };

    let system = state.system.clone();
    let action = action.to_string();
    match blocking(move || system.power(&action)).await {
        Ok(Ok(())) => json_response(StatusCode::OK, &serde_json::json!({ "ok": true })),
        Ok(Err(message)) => error_response(StatusCode::INTERNAL_SERVER_ERROR, message),
        Err(()) => internal_error(),
    }
}

async fn jobs(State(state): State<AppState>) -> Response {
    json_response(StatusCode::OK, &state.jobs.list())
}

async fn job(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    match state.jobs.snapshot(&id) {
        Some(job) => json_response(StatusCode::OK, &job),
        None => error_response(StatusCode::NOT_FOUND, "job not found"),
    }
}

async fn job_cancel(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    match state.jobs.cancel(&id) {
        Some(job) => json_response(StatusCode::OK, &job),
        None => error_response(StatusCode::NOT_FOUND, "job not found"),
    }
}

#[allow(clippy::result_large_err)]
fn decode_json<T: DeserializeOwned>(body: Bytes) -> Result<T, Response> {
    serde_json::from_slice(&body).map_err(|error| {
        error_response(
            StatusCode::BAD_REQUEST,
            format!("invalid JSON body: {error}"),
        )
    })
}

fn internal_error() -> Response {
    error_response(StatusCode::INTERNAL_SERVER_ERROR, "internal server error")
}

async fn not_found() -> Response {
    Response::builder()
        .status(StatusCode::NOT_FOUND)
        .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
        .body(Body::from("404 page not found\n"))
        .expect("valid response")
}
