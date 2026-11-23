use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::body::{Body, Bytes};
use axum::extract::connect_info::ConnectInfo;
use axum::extract::{DefaultBodyLimit, Path, Query, Request, State};
use axum::http::{header, HeaderValue, Method, StatusCode};
use axum::middleware::{self, Next};
use axum::response::Response;
use axum::routing::{get, post};
use axum::Router;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use tower_http::catch_panic::CatchPanicLayer;

use crate::activity::{ActivityStore, NewActivity};
use crate::config::AppConfig;
use crate::history::{StatusHistory, StatusHistoryResponse};
use crate::jobs::JobLauncher;
use crate::models::{
    HistoryEntry, LoginSession, LogsResponse, SessionAction, SessionDetail, SessionSummary,
    SessionsResponse,
};
use crate::peripherals::PeripheralProbe;
use crate::resources::ResourceProbe;
use crate::system::SystemProbe;
use crate::themes::{self, ThemeApplyRequest};
use crate::util::{
    parse_lines_param, valid_pool_name, valid_session_id, valid_token, valid_unit_name,
};

#[derive(Clone)]
pub struct AppState {
    pub config: AppConfig,
    pub system: Arc<dyn SystemProbe>,
    pub jobs: Arc<dyn JobLauncher>,
    pub peripherals: Arc<dyn PeripheralProbe>,
    pub activity: Arc<ActivityStore>,
    pub history: Arc<StatusHistory>,
    pub resources: Arc<dyn ResourceProbe>,
    pub version: String,
}

pub fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/api/health", get(health))
        .route("/api/status", get(status))
        .route("/api/status/history", get(status_history))
        .route("/api/resources", get(resources))
        .route("/api/themes", get(theme_catalog))
        .route("/api/themes/apply", post(apply_theme))
        .route("/api/peripherals", get(peripherals))
        .route("/api/services", get(service_units))
        .route("/api/services/{unit}/{action}", post(service_action))
        .route("/api/services/{unit}/logs", get(service_logs))
        .route("/api/storage", get(storage))
        .route("/api/storage/pools/{name}", get(pool_status))
        .route("/api/system/generations", get(generations))
        .route("/api/system/generations/diff", get(generation_diff))
        .route("/api/system/rebuild", post(rebuild))
        .route("/api/system/power", post(power))
        .route("/api/logs", get(system_logs))
        .route("/api/sessions", get(sessions))
        .route("/api/sessions/{id}", get(session_detail))
        .route("/api/jobs", get(jobs))
        .route("/api/jobs/{id}", get(job))
        .route("/api/jobs/{id}/cancel", post(job_cancel))
        .fallback(not_found)
        .with_state(state.clone())
        .layer(DefaultBodyLimit::max(1024 * 1024))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            record_activity,
        ))
        .layer(middleware::from_fn_with_state(state.clone(), require_auth))
        .layer(middleware::from_fn(security_headers))
        .layer(middleware::from_fn(cors_peripherals))
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

async fn cors_peripherals(request: Request, next: Next) -> Response {
    let is_readonly =
        request.uri().path() == "/api/peripherals" || request.uri().path() == "/api/health";
    if is_readonly && request.method() == Method::OPTIONS {
        return Response::builder()
            .status(StatusCode::NO_CONTENT)
            .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
            .header(
                header::ACCESS_CONTROL_ALLOW_HEADERS,
                "Authorization, Content-Type",
            )
            .header(header::ACCESS_CONTROL_ALLOW_METHODS, "GET, OPTIONS")
            .header(header::ACCESS_CONTROL_MAX_AGE, "600")
            .body(Body::empty())
            .expect("valid response");
    }

    let mut response = next.run(request).await;
    if is_readonly {
        let headers = response.headers_mut();
        headers.insert(
            header::ACCESS_CONTROL_ALLOW_ORIGIN,
            HeaderValue::from_static("*"),
        );
        headers.insert(
            header::ACCESS_CONTROL_ALLOW_HEADERS,
            HeaderValue::from_static("Authorization, Content-Type"),
        );
        headers.insert(
            header::ACCESS_CONTROL_ALLOW_METHODS,
            HeaderValue::from_static("GET, OPTIONS"),
        );
    }
    response
}

async fn require_auth(State(state): State<AppState>, request: Request, next: Next) -> Response {
    if request.method() == Method::OPTIONS {
        return next.run(request).await;
    }

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

/// Record mutating requests in the activity audit trail. The response body is
/// inspected for an error message and rebuild job id, then passed through
/// unchanged.
async fn record_activity(State(state): State<AppState>, request: Request, next: Next) -> Response {
    let method = request.method().clone();
    if method == Method::GET || method == Method::HEAD || method == Method::OPTIONS {
        return next.run(request).await;
    }

    let path = request.uri().path().to_string();
    let started = Instant::now();
    let (source, client, actor_key) = actor_info(&request);

    // Rebuild and power requests carry the chosen action in a small JSON body.
    // Read it before the handler consumes the request so the audit entry can
    // show what was requested.
    let mut body_action = None;
    let request = if path == "/api/system/rebuild"
        || path == "/api/system/power"
        || path == "/api/themes/apply"
    {
        let (parts, body) = request.into_parts();
        let bytes = match axum::body::to_bytes(body, 1024 * 1024 + 1).await {
            Ok(bytes) => bytes,
            Err(_) => {
                return error_response(StatusCode::PAYLOAD_TOO_LARGE, "request body too large")
            }
        };
        body_action = serde_json::from_slice::<serde_json::Value>(&bytes)
            .ok()
            .and_then(|value| {
                value
                    .get("action")
                    .or_else(|| value.get("profile"))
                    .or_else(|| value.get("gtkTheme"))
                    .and_then(|value| value.as_str())
                    .map(str::to_string)
            });
        Request::from_parts(parts, Body::from(bytes))
    } else {
        request
    };

    let response = next.run(request).await;
    let status = response.status();
    let (parts, body) = response.into_parts();
    // Mutating endpoints return either a small status object or a job snapshot
    // whose captured output is capped at 64 KiB by the job manager. Two
    // megabytes leaves room for JSON escaping while keeping the buffer bounded.
    let bytes = axum::body::to_bytes(body, 2 * 1024 * 1024)
        .await
        .unwrap_or_default();
    let payload: Option<serde_json::Value> = serde_json::from_slice(&bytes).ok();
    let error = payload
        .as_ref()
        .and_then(|value| value.get("error"))
        .and_then(|value| value.as_str())
        .map(str::to_string);
    let job_id = if path == "/api/system/rebuild" {
        payload
            .as_ref()
            .and_then(|value| value.get("id"))
            .and_then(|value| value.as_str())
            .map(str::to_string)
    } else {
        None
    };

    let (action, target) = describe_action(&method, &path, body_action);
    let status_tone = match status.as_u16() {
        401 | 403 => "denied",
        200..=299 => "ok",
        _ => "failed",
    };
    let detail = match (&error, &job_id) {
        (Some(error), _) => Some(error.clone()),
        (None, Some(job_id)) => Some(format!("job {job_id}")),
        (None, None) => None,
    };

    state.activity.record(NewActivity {
        actor_key,
        source,
        action,
        target,
        status: status_tone.to_string(),
        detail,
        job_id,
        client,
        method: method.to_string(),
        path,
        status_code: status.as_u16(),
        duration_ms: started.elapsed().as_millis() as u64,
    });

    Response::from_parts(parts, Body::from(bytes))
}

/// Classify the caller by user agent and address. The iOS app sends a
/// `NixOSControl` user agent; browsers send `Mozilla`/`WebKit`; anything else
/// is treated as a generic API client.
fn actor_info(request: &Request) -> (String, Option<String>, String) {
    let user_agent = request
        .headers()
        .get(header::USER_AGENT)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("");
    let lowered = user_agent.to_ascii_lowercase();
    let source = if lowered.contains("nixoscontrol") {
        "ios"
    } else if lowered.contains("mozilla") || lowered.contains("webkit") {
        "web"
    } else {
        "api"
    };

    let forwarded = request
        .headers()
        .get("x-forwarded-for")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(',').next())
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let real_ip = request
        .headers()
        .get("x-real-ip")
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let peer = request
        .extensions()
        .get::<ConnectInfo<SocketAddr>>()
        .map(|ConnectInfo(address)| address.ip().to_string());

    let client = forwarded
        .map(str::to_string)
        .or_else(|| real_ip.map(str::to_string))
        .or(peer);

    let agent: String = user_agent.chars().take(80).collect();
    let actor_key = format!("{source}|{}|{agent}", client.as_deref().unwrap_or("-"));
    (source.to_string(), client, actor_key)
}

fn describe_action(
    method: &Method,
    path: &str,
    body_action: Option<String>,
) -> (String, Option<String>) {
    let segments: Vec<&str> = path
        .trim_start_matches("/api/")
        .split('/')
        .filter(|segment| !segment.is_empty())
        .collect();

    match segments.as_slice() {
        ["services", unit, action] => (action.to_string(), Some(unit.to_string())),
        ["system", "rebuild"] => ("rebuild".to_string(), body_action),
        ["system", "power"] => ("power".to_string(), body_action),
        ["themes", "apply"] => ("apply theme".to_string(), body_action),
        ["jobs", id, "cancel"] => ("cancel".to_string(), Some(format!("job {id}"))),
        _ => (method.as_str().to_ascii_lowercase(), Some(path.to_string())),
    }
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

#[derive(Debug, Default, Deserialize)]
struct StatusHistoryQuery {
    minutes: Option<String>,
    limit: Option<String>,
}

async fn status_history(
    State(state): State<AppState>,
    Query(query): Query<StatusHistoryQuery>,
) -> Response {
    let minutes = query
        .minutes
        .as_deref()
        .and_then(|value| value.trim().parse::<i64>().ok())
        .unwrap_or(60)
        .clamp(1, 360);
    let limit = query
        .limit
        .as_deref()
        .and_then(|value| value.trim().parse::<usize>().ok())
        .unwrap_or(720)
        .clamp(1, 2160);
    let samples = state.history.samples(minutes, limit);
    json_response(StatusCode::OK, &StatusHistoryResponse { samples })
}

async fn resources(State(state): State<AppState>) -> Response {
    match state.resources.snapshot() {
        Some(usage) => json_response(StatusCode::OK, &usage),
        None => error_response(
            StatusCode::SERVICE_UNAVAILABLE,
            "resource sampler is starting",
        ),
    }
}

async fn theme_catalog(State(state): State<AppState>) -> Response {
    json_response(StatusCode::OK, &themes::catalog(&state.config))
}

async fn apply_theme(State(state): State<AppState>, body: Bytes) -> Response {
    if !state.config.allow_rebuild {
        return error_response(
            StatusCode::FORBIDDEN,
            "theme changes are disabled on this server",
        );
    }

    let request: ThemeApplyRequest = match decode_json(body) {
        Ok(request) => request,
        Err(response) => return response,
    };

    let theme = match themes::apply(&state.config, request) {
        Ok(theme) => theme,
        Err(message) => return error_response(StatusCode::BAD_REQUEST, message),
    };
    let job = start_rebuild_job(&state, "switch");
    json_response(
        StatusCode::ACCEPTED,
        &serde_json::json!({ "theme": theme, "job": job }),
    )
}

fn start_rebuild_job(state: &AppState, action: &str) -> crate::jobs::Job {
    let mut args = vec![action.to_string()];
    if let Some(flake) = &state.config.flake {
        args.push("--flake".to_string());
        args.push(flake.clone());
    }
    let dir = if state.config.nixos_dir.is_dir() {
        Some(state.config.nixos_dir.clone())
    } else {
        None
    };
    state.jobs.start(
        &format!("nixos-rebuild {action}"),
        "nixos-rebuild",
        args,
        dir,
    )
}

async fn peripherals(State(state): State<AppState>) -> Response {
    let peripherals = state.peripherals.clone();
    match blocking(move || peripherals.snapshot()).await {
        Ok(Ok(report)) => json_response(StatusCode::OK, &report),
        Ok(Err(message)) => error_response(StatusCode::SERVICE_UNAVAILABLE, message),
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

#[derive(Debug, Default, Deserialize)]
struct LimitQuery {
    limit: Option<String>,
}

fn parse_limit(value: Option<&str>, fallback: usize, max: usize) -> usize {
    let parsed = value.and_then(|value| value.trim().parse::<usize>().ok());
    match parsed {
        Some(value) if value > 0 => value.min(max),
        _ => fallback,
    }
}

fn login_source(session: &LoginSession) -> &'static str {
    let service = session.service.to_ascii_lowercase();
    if service.contains("sshd") || service.contains("ssh") {
        "ssh"
    } else if service.contains("xrdp") {
        "rdp"
    } else {
        "console"
    }
}

fn login_summary(session: &LoginSession) -> SessionSummary {
    let source = login_source(session);
    let place = session
        .tty
        .clone()
        .or_else(|| session.seat.clone())
        .or_else(|| {
            if session.kind.is_empty() {
                None
            } else {
                Some(session.kind.clone())
            }
        })
        .unwrap_or_else(|| "session".to_string());
    let title = format!("{} · {}", session.user, place);
    let summary = match (&session.remote_host, session.remote) {
        (Some(host), _) => format!("Remote login from {host}"),
        (None, true) => "Remote login".to_string(),
        (None, false) => format!(
            "{} login on {}",
            if session.kind.is_empty() {
                "Local"
            } else {
                session.kind.as_str()
            },
            place
        ),
    };

    SessionSummary {
        id: format!("login-{}", session.id),
        kind: "login".to_string(),
        source: source.to_string(),
        title,
        user: Some(session.user.clone()),
        tty: session.tty.clone(),
        seat: session.seat.clone(),
        remote_host: session.remote_host.clone(),
        service: if session.service.is_empty() {
            None
        } else {
            Some(session.service.clone())
        },
        state: if session.active {
            "active".to_string()
        } else if session.state.is_empty() {
            "ended".to_string()
        } else {
            session.state.clone()
        },
        started_at: session.started_at.clone(),
        last_active_at: session.started_at.clone(),
        action_count: 0,
        status: "ok".to_string(),
        summary,
    }
}

async fn sessions(State(state): State<AppState>, Query(query): Query<LimitQuery>) -> Response {
    let limit = parse_limit(query.limit.as_deref(), 50, 200);
    let mut summaries = state.activity.sessions(limit);

    let system = state.system.clone();
    if let Ok(sessions) = blocking(move || system.login_sessions()).await {
        summaries.extend(sessions.iter().map(login_summary));
    }

    summaries.sort_by(|left, right| right.last_active_at.cmp(&left.last_active_at));
    summaries.truncate(limit);
    json_response(
        StatusCode::OK,
        &SessionsResponse {
            sessions: summaries,
        },
    )
}

async fn session_detail(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<LinesQuery>,
) -> Response {
    let lines = parse_lines_param(query.lines.as_deref().unwrap_or(""), 300);

    if let Some(raw_id) = id.strip_prefix("login-") {
        let raw_id = raw_id.to_string();
        if !valid_session_id(&raw_id) {
            return error_response(StatusCode::BAD_REQUEST, "invalid session id");
        }

        let system = state.system.clone();
        let lookup = raw_id.clone();
        let sessions = match blocking(move || system.login_sessions()).await {
            Ok(sessions) => sessions,
            Err(()) => return internal_error(),
        };
        let Some(session) = sessions.into_iter().find(|session| session.id == lookup) else {
            return error_response(StatusCode::NOT_FOUND, "session not found");
        };

        let since = chrono::DateTime::parse_from_rfc3339(&session.started_at)
            .ok()
            .map(|value| value.timestamp());
        let user = session.user.clone();

        let system = state.system.clone();
        let log_id = raw_id.clone();
        let logs = match blocking(move || system.login_session_logs(&log_id, lines)).await {
            Ok(Ok(lines)) => lines,
            _ => Vec::new(),
        };

        let system = state.system.clone();
        let history_user = user.clone();
        // A graphical login owns a tty such as tty7, while terminals inside
        // the session run on pts/*. Only filter by tty for real shell sessions.
        let history_tty = if session.kind.is_empty() || session.kind == "tty" {
            session.tty.clone()
        } else {
            None
        };
        let commands: Vec<HistoryEntry> = blocking(move || {
            system.login_session_history(&history_user, history_tty.as_deref(), since, 300)
        })
        .await
        .unwrap_or_default();

        let mut summary = login_summary(&session);
        summary.action_count = commands.len();
        if !commands.is_empty() {
            summary.summary = format!("{} · {} commands", summary.summary, commands.len());
        }

        return json_response(
            StatusCode::OK,
            &SessionDetail {
                summary,
                actions: Vec::new(),
                logs,
                commands,
            },
        );
    }

    let Some(summary) = state.activity.session_summary(&id) else {
        return error_response(StatusCode::NOT_FOUND, "session not found");
    };
    let events = state.activity.session_events(&id).unwrap_or_default();
    let actions: Vec<SessionAction> = events
        .into_iter()
        .map(|event| {
            let output = event
                .job_id
                .as_ref()
                .and_then(|job_id| state.jobs.snapshot(job_id))
                .map(|job| job.output)
                .filter(|text| !text.trim().is_empty());
            SessionAction {
                id: event.id,
                at: event.at,
                action: event.action,
                target: event.target,
                status: event.status,
                detail: event.detail,
                job_id: event.job_id,
                output,
                method: Some(event.method),
                path: Some(event.path),
                status_code: Some(event.status_code),
                duration_ms: Some(event.duration_ms),
            }
        })
        .collect();

    json_response(
        StatusCode::OK,
        &SessionDetail {
            summary,
            actions,
            logs: Vec::new(),
            commands: Vec::new(),
        },
    )
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
        Ok(Ok(logs)) => lines_body(unit, logs),
        Ok(Err(message)) => error_response(StatusCode::INTERNAL_SERVER_ERROR, message),
        Err(()) => internal_error(),
    }
}

fn lines_body(unit: String, logs: LogsResponse) -> Response {
    let value = serde_json::json!({
        "unit": unit,
        "lines": logs.lines,
        "entries": logs.entries,
    });
    json_response(StatusCode::OK, &value)
}

async fn system_logs(State(state): State<AppState>, Query(query): Query<LinesQuery>) -> Response {
    let lines = parse_lines_param(query.lines.as_deref().unwrap_or(""), 300);
    let system = state.system.clone();
    match blocking(move || system.system_logs(lines)).await {
        Ok(Ok(logs)) => json_response(StatusCode::OK, &logs),
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

#[derive(Debug, Default, Deserialize)]
struct GenerationDiffQuery {
    from: Option<String>,
    to: Option<String>,
}

fn parse_generation_param(key: &str, value: Option<&str>) -> Result<i32, String> {
    let value = value.ok_or_else(|| format!("{key} is required"))?;
    let number: i32 = value
        .trim()
        .parse()
        .map_err(|_| format!("invalid {key} generation"))?;
    if number <= 0 {
        return Err(format!("invalid {key} generation"));
    }
    Ok(number)
}

async fn generation_diff(
    State(state): State<AppState>,
    Query(query): Query<GenerationDiffQuery>,
) -> Response {
    let from = match parse_generation_param("from", query.from.as_deref()) {
        Ok(number) => number,
        Err(message) => return error_response(StatusCode::BAD_REQUEST, message),
    };
    let to = match parse_generation_param("to", query.to.as_deref()) {
        Ok(number) => number,
        Err(message) => return error_response(StatusCode::BAD_REQUEST, message),
    };

    let system = state.system.clone();
    match blocking(move || system.generation_diff(from, to)).await {
        Ok(Ok(diff)) => json_response(StatusCode::OK, &diff),
        Ok(Err(message)) => error_response(StatusCode::BAD_REQUEST, message),
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

    let job = start_rebuild_job(&state, &request.action);
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
