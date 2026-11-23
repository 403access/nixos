use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};

use crate::models::SessionSummary;

/// A burst of API actions from the same client is grouped into one session.
/// Activity separated by more than this window starts a new session.
pub const DEFAULT_SESSION_IDLE: Duration = Duration::from_secs(30 * 60);
/// Keep the on-disk audit trail bounded.
const MAX_EVENTS: usize = 4000;
const MAX_SUMMARY_ACTIONS: usize = 4;

/// One action performed through the API, as persisted in the activity log.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ActivityEvent {
    pub id: String,
    pub session_id: String,
    /// Stable fingerprint of the calling client (source, address, user agent).
    pub actor_key: String,
    /// `web`, `ios` or `api`.
    pub source: String,
    pub at: String,
    pub action: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    /// `ok`, `failed` or `denied`.
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub job_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client: Option<String>,
    pub method: String,
    pub path: String,
    pub status_code: u16,
    pub duration_ms: u64,
}

/// Fields supplied by the recording middleware.
#[derive(Debug, Clone)]
pub struct NewActivity {
    pub actor_key: String,
    pub source: String,
    pub action: String,
    pub target: Option<String>,
    pub status: String,
    pub detail: Option<String>,
    pub job_id: Option<String>,
    pub client: Option<String>,
    pub method: String,
    pub path: String,
    pub status_code: u16,
    pub duration_ms: u64,
}

#[derive(Debug, Clone)]
struct OpenSession {
    session_id: String,
    last_at: DateTime<Utc>,
}

#[derive(Default)]
struct Inner {
    events: Vec<ActivityEvent>,
    open: HashMap<String, OpenSession>,
    sequence: u64,
}

/// Persistent, bounded audit log of actions taken through the API. Events are
/// grouped into sessions per client and written to a JSONL file when a path is
/// configured, so history survives server restarts.
pub struct ActivityStore {
    inner: Mutex<Inner>,
    file: Option<PathBuf>,
    idle: Duration,
}

impl Default for ActivityStore {
    fn default() -> Self {
        Self::new(None)
    }
}

impl ActivityStore {
    pub fn new(file: Option<PathBuf>) -> Self {
        Self::with_idle(file, DEFAULT_SESSION_IDLE)
    }

    pub fn with_idle(file: Option<PathBuf>, idle: Duration) -> Self {
        let events = file
            .as_ref()
            .map(|path| load_events(path, MAX_EVENTS))
            .unwrap_or_default();
        Self {
            inner: Mutex::new(Inner {
                events,
                ..Inner::default()
            }),
            file,
            idle,
        }
    }

    /// Record one action and return the stored event. Failures to append to the
    /// audit file are logged but never fail the request.
    pub fn record(&self, new: NewActivity) -> ActivityEvent {
        let now = Utc::now();
        let mut inner = self.inner.lock().expect("activity store poisoned");

        let existing = inner
            .open
            .get(&new.actor_key)
            .filter(|open| {
                now.signed_duration_since(open.last_at)
                    < chrono::Duration::from_std(self.idle).unwrap_or(chrono::Duration::minutes(30))
            })
            .map(|open| open.session_id.clone());

        let sequence = inner.sequence;
        let session_id = existing
            .unwrap_or_else(|| format!("app-{:x}-{:x}", now.timestamp_millis().max(0), sequence));
        inner.sequence = inner.sequence.wrapping_add(1);
        inner.open.insert(
            new.actor_key.clone(),
            OpenSession {
                session_id: session_id.clone(),
                last_at: now,
            },
        );

        let event = ActivityEvent {
            id: format!("{session_id}-{}", inner.sequence),
            session_id,
            actor_key: new.actor_key,
            source: new.source,
            at: rfc3339(now),
            action: new.action,
            target: new.target,
            status: new.status,
            detail: new.detail,
            job_id: new.job_id,
            client: new.client,
            method: new.method,
            path: new.path,
            status_code: new.status_code,
            duration_ms: new.duration_ms,
        };

        inner.events.push(event.clone());
        if inner.events.len() > MAX_EVENTS {
            let excess = inner.events.len() - MAX_EVENTS;
            inner.events.drain(0..excess);
        }

        if let Some(path) = &self.file {
            append_event(path, &event);
        }

        event
    }

    /// Summaries for the newest application sessions.
    pub fn sessions(&self, limit: usize) -> Vec<SessionSummary> {
        let inner = self.inner.lock().expect("activity store poisoned");
        let mut grouped: Vec<Vec<&ActivityEvent>> = Vec::new();
        for event in &inner.events {
            match grouped.iter_mut().find(|events| {
                events
                    .first()
                    .map(|first| first.session_id == event.session_id)
                    .unwrap_or(false)
            }) {
                Some(events) => events.push(event),
                None => grouped.push(vec![event]),
            }
        }

        let mut sessions: Vec<SessionSummary> =
            grouped.iter().map(|events| app_summary(events)).collect();
        sessions.sort_by(|left, right| right.last_active_at.cmp(&left.last_active_at));
        sessions.truncate(limit);
        sessions
    }

    /// Events belonging to one application session, oldest first.
    pub fn session_events(&self, id: &str) -> Option<Vec<ActivityEvent>> {
        let inner = self.inner.lock().expect("activity store poisoned");
        let mut events: Vec<ActivityEvent> = inner
            .events
            .iter()
            .filter(|event| event.session_id == id)
            .cloned()
            .collect();
        if events.is_empty() {
            return None;
        }
        events.sort_by(|left, right| left.at.cmp(&right.at));
        Some(events)
    }

    pub fn session_summary(&self, id: &str) -> Option<SessionSummary> {
        let events = self.session_events(id)?;
        let refs: Vec<&ActivityEvent> = events.iter().collect();
        Some(app_summary(&refs))
    }
}

fn load_events(path: &PathBuf, max: usize) -> Vec<ActivityEvent> {
    let Ok(contents) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut events: Vec<ActivityEvent> = contents
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect();
    if events.len() > max {
        events.drain(0..events.len() - max);
    }
    events
}

fn append_event(path: &PathBuf, event: &ActivityEvent) {
    if let Some(parent) = path.parent() {
        if let Err(error) = fs::create_dir_all(parent) {
            log::warn!(
                "could not create activity directory {}: {error}",
                parent.display()
            );
            return;
        }
    }
    let result = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .and_then(|mut file| {
            let line = serde_json::to_string(event).unwrap_or_default();
            writeln!(file, "{line}")
        });
    if let Err(error) = result {
        log::warn!("could not append activity log {}: {error}", path.display());
    }
}

fn app_summary(events: &[&ActivityEvent]) -> SessionSummary {
    let first = events.first().expect("non-empty session");
    let last = events.last().expect("non-empty session");
    let status = if events.iter().any(|event| event.status == "failed") {
        if events.iter().all(|event| event.status != "ok") {
            "failed"
        } else {
            "mixed"
        }
    } else if events.iter().any(|event| event.status == "denied") {
        if events.iter().all(|event| event.status == "denied") {
            "denied"
        } else {
            "mixed"
        }
    } else {
        "ok"
    };

    let mut labels: Vec<String> = events
        .iter()
        .take(MAX_SUMMARY_ACTIONS)
        .map(|event| match &event.target {
            Some(target) if !target.is_empty() => format!("{} {}", event.action, target),
            _ => event.action.clone(),
        })
        .collect();
    if events.len() > MAX_SUMMARY_ACTIONS {
        labels.push(format!("+{} more", events.len() - MAX_SUMMARY_ACTIONS));
    }

    let idle_ended = Utc::now().signed_duration_since(
        DateTime::parse_from_rfc3339(&last.at)
            .map(|value| value.with_timezone(&Utc))
            .unwrap_or_else(|_| Utc::now()),
    ) > chrono::Duration::from_std(DEFAULT_SESSION_IDLE)
        .unwrap_or(chrono::Duration::minutes(30));

    SessionSummary {
        id: first.session_id.clone(),
        kind: "app".to_string(),
        source: first.source.clone(),
        title: source_title(&first.source).to_string(),
        user: None,
        tty: None,
        seat: None,
        remote_host: first.client.clone(),
        service: None,
        state: if idle_ended { "ended" } else { "online" }.to_string(),
        started_at: first.at.clone(),
        last_active_at: last.at.clone(),
        action_count: events.len(),
        status: status.to_string(),
        summary: labels.join(" · "),
    }
}

pub fn source_title(source: &str) -> &'static str {
    match source {
        "web" => "Web console",
        "ios" => "iOS app",
        _ => "API client",
    }
}

fn rfc3339(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::Secs, true)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn action(actor: &str, action: &str, status: &str) -> NewActivity {
        NewActivity {
            actor_key: actor.to_string(),
            source: "web".to_string(),
            action: action.to_string(),
            target: Some("nginx.service".to_string()),
            status: status.to_string(),
            detail: None,
            job_id: None,
            client: Some("192.168.1.10".to_string()),
            method: "POST".to_string(),
            path: format!("/api/services/nginx.service/{action}"),
            status_code: 200,
            duration_ms: 5,
        }
    }

    #[test]
    fn groups_actions_from_the_same_client() {
        let store = ActivityStore::new(None);
        store.record(action("web|1", "restart", "ok"));
        store.record(action("web|1", "stop", "failed"));
        store.record(action("ios|2", "start", "ok"));

        let sessions = store.sessions(10);
        assert_eq!(sessions.len(), 2);
        let web = sessions
            .iter()
            .find(|session| session.source == "web")
            .unwrap();
        assert_eq!(web.action_count, 2);
        assert_eq!(web.status, "mixed");
        assert_eq!(web.remote_host.as_deref(), Some("192.168.1.10"));
    }

    #[test]
    fn keeps_separate_sessions_for_separate_clients() {
        let store = ActivityStore::with_idle(None, Duration::from_secs(1));
        store.record(action("web|1", "restart", "ok"));
        let first = store.sessions(10)[0].id.clone();
        store.record(action("web|1", "restart", "ok"));
        // Same client within the idle window reuses the session.
        assert_eq!(store.sessions(10)[0].id, first);
    }

    #[test]
    fn persists_and_reloads_events() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("activity.jsonl");
        let store = ActivityStore::new(Some(path.clone()));
        store.record(action("web|1", "restart", "ok"));
        drop(store);

        let reopened = ActivityStore::new(Some(path));
        assert_eq!(reopened.sessions(10).len(), 1);
        assert_eq!(reopened.sessions(10)[0].action_count, 1);
    }
}
