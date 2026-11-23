use std::cmp::Ordering;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::time::Duration;

use chrono::{DateTime, Local, NaiveDate, NaiveDateTime, NaiveTime, SecondsFormat, TimeZone, Utc};
use serde::Deserialize;

use crate::commands::CommandRunner;
use crate::models::{HistoryEntry, LoginSession};
use crate::util::{split_lines, valid_session_id};

const SHOW_TIMEOUT: Duration = Duration::from_secs(10);
const JOURNAL_TIMEOUT: Duration = Duration::from_secs(20);
const HISTORY_TAIL_BYTES: u64 = 256 * 1024;
const MAX_COMMANDS: usize = 300;
/// Command log timestamps can be a few seconds before logind's session start.
const COMMAND_LOG_GRACE_SECONDS: i64 = 5;

/// Collect the sessions systemd-logind currently knows about.
pub fn collect_login_sessions(runner: &dyn CommandRunner) -> Vec<LoginSession> {
    let listing = runner.run(
        "loginctl",
        &["list-sessions", "--no-legend", "--no-pager"],
        SHOW_TIMEOUT,
    );
    if listing.error.is_some() && listing.output.trim().is_empty() {
        return Vec::new();
    }

    let mut sessions = Vec::new();
    for line in split_lines(&listing.output) {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 3 {
            continue;
        }
        let id = fields[0];
        if !valid_session_id(id) {
            continue;
        }
        let uid = fields[1].parse::<u32>().ok();
        let user = fields[2].to_string();
        let seat = fields
            .get(3)
            .filter(|value| **value != "-")
            .map(|value| value.to_string());
        // Newer systemd adds LEADER, CLASS, TTY, IDLE and SINCE columns. The
        // old five-column format put the TTY at index 4.
        let tty_field = if fields.len() >= 7 {
            fields.get(6)
        } else {
            fields.get(4)
        };
        let tty = tty_field
            .filter(|value| **value != "-")
            .map(|value| value.to_string());

        let mut session = LoginSession {
            id: id.to_string(),
            user,
            uid,
            seat: seat.clone(),
            tty: tty.clone(),
            remote: false,
            remote_host: None,
            service: String::new(),
            kind: String::new(),
            class: String::new(),
            state: "active".to_string(),
            active: true,
            started_at: String::new(),
        };

        if let Some(properties) = show_session(runner, id) {
            apply_properties(&mut session, &properties);
        }

        // `loginctl` formats Timestamp, so ask for the value on its own and
        // accept both raw microseconds and human-readable output.
        if let Some(timestamp) = show_session_timestamp(runner, id) {
            session.started_at = timestamp;
        }

        sessions.push(session);
    }

    sessions.sort_by(|left, right| right.started_at.cmp(&left.started_at));
    sessions
}

fn show_session(runner: &dyn CommandRunner, id: &str) -> Option<Vec<(String, String)>> {
    let result = runner.run(
        "loginctl",
        &[
            "show-session",
            id,
            "--no-pager",
            "-p",
            "Id",
            "-p",
            "Name",
            "-p",
            "Remote",
            "-p",
            "RemoteHost",
            "-p",
            "Service",
            "-p",
            "Type",
            "-p",
            "Class",
            "-p",
            "State",
            "-p",
            "TTY",
            "-p",
            "Seat",
            "-p",
            "Active",
        ],
        SHOW_TIMEOUT,
    );
    if result.output.trim().is_empty() {
        return None;
    }
    let properties = split_lines(&result.output)
        .into_iter()
        .filter_map(|line| {
            let (key, value) = line.split_once('=')?;
            Some((key.to_string(), value.to_string()))
        })
        .collect();
    Some(properties)
}

fn show_session_timestamp(runner: &dyn CommandRunner, id: &str) -> Option<String> {
    let result = runner.run(
        "loginctl",
        &[
            "show-session",
            id,
            "--no-pager",
            "-p",
            "Timestamp",
            "--value",
        ],
        SHOW_TIMEOUT,
    );
    let raw = result.output.trim();
    if raw.is_empty() {
        return None;
    }
    match parse_session_timestamp(raw) {
        Some(value) => Some(value.to_rfc3339_opts(SecondsFormat::Secs, true)),
        None => Some(raw.to_string()),
    }
}

fn apply_properties(session: &mut LoginSession, properties: &[(String, String)]) {
    for (key, value) in properties {
        match key.as_str() {
            "Id" if valid_session_id(value) => session.id = value.clone(),
            "Name" if !value.is_empty() => session.user = value.clone(),
            "Remote" => session.remote = *value == "yes" || *value == "true",
            "RemoteHost" if !value.is_empty() => session.remote_host = Some(value.clone()),
            "Service" => session.service = value.clone(),
            "Type" => session.kind = value.clone(),
            "Class" => session.class = value.clone(),
            "State" => session.state = value.clone(),
            "TTY" if !value.is_empty() && value != "-" => session.tty = Some(value.clone()),
            "Seat" if !value.is_empty() && value != "-" => session.seat = Some(value.clone()),
            "Active" => session.active = *value == "yes" || *value == "true",
            _ => {}
        }
    }
}

fn parse_session_timestamp(raw: &str) -> Option<DateTime<Utc>> {
    let raw = raw.trim();
    if raw.is_empty() || raw == "n/a" {
        return None;
    }

    if raw.chars().all(|character| character.is_ascii_digit()) {
        if let Ok(micros) = raw.parse::<i64>() {
            let seconds = micros.div_euclid(1_000_000);
            let nanos = (micros.rem_euclid(1_000_000) * 1_000) as u32;
            return Utc.timestamp_opt(seconds, nanos).single();
        }
    }

    if let Ok(value) = DateTime::parse_from_rfc3339(raw) {
        return Some(value.with_timezone(&Utc));
    }

    // `loginctl` often prints "Sat 2025-11-22 23:00:00 CET". Pull out the date
    // and time and treat the value as host local time.
    let parts: Vec<&str> = raw.split_whitespace().collect();
    for pair in parts.windows(2) {
        if let (Ok(date), Ok(time)) = (
            NaiveDate::parse_from_str(pair[0], "%Y-%m-%d"),
            NaiveTime::parse_from_str(pair[1], "%H:%M:%S"),
        ) {
            let naive = NaiveDateTime::new(date, time);
            if let Some(local) = Local.from_local_datetime(&naive).single() {
                return Some(local.with_timezone(&Utc));
            }
            return Some(naive.and_utc());
        }
    }

    None
}

/// Journal lines that belong to a logind session.
pub fn session_logs(
    runner: &dyn CommandRunner,
    id: &str,
    lines: usize,
) -> Result<Vec<String>, String> {
    if !valid_session_id(id) {
        return Err("invalid session id".to_string());
    }
    let lines = lines.to_string();

    let primary = runner.run(
        "journalctl",
        &[
            &format!("_SYSTEMD_SESSION={id}"),
            "-n",
            &lines,
            "--no-pager",
            "-o",
            "short-iso",
        ],
        JOURNAL_TIMEOUT,
    );
    let primary_lines = split_lines(&primary.output);
    if !primary_lines.is_empty() {
        return Ok(primary_lines);
    }

    let fallback = runner.run(
        "journalctl",
        &[
            &format!("_SYSTEMD_UNIT=session-{id}.scope"),
            "-n",
            &lines,
            "--no-pager",
            "-o",
            "short-iso",
        ],
        JOURNAL_TIMEOUT,
    );
    let fallback_lines = split_lines(&fallback.output);
    if !fallback_lines.is_empty() {
        return Ok(fallback_lines);
    }

    match (primary.error, fallback.error) {
        (Some(primary_error), Some(fallback_error)) => {
            Err(format!("{primary_error}; {fallback_error}"))
        }
        (Some(error), None) | (None, Some(error)) => Err(error),
        (None, None) => Ok(Vec::new()),
    }
}

/// Recent commands for a session. Prefer the structured shell audit log (which
/// records start time, duration, exit status and working directory) and fall
/// back to zsh/bash history for older commands.
pub fn shell_history(
    user: &str,
    tty: Option<&str>,
    since_epoch: Option<i64>,
    limit: usize,
) -> Vec<HistoryEntry> {
    let limit = limit.clamp(1, MAX_COMMANDS);
    let home = home_directory(user);
    let mut entries = read_command_log(user, tty, since_epoch);
    let has_log = !entries.is_empty();

    let mut history = Vec::new();
    if let Some(contents) = read_tail(&home.join(".zsh_history")) {
        history.extend(parse_zsh_history(&contents, since_epoch));
    }
    if let Some(contents) = read_tail(&home.join(".bash_history")) {
        history.extend(parse_bash_history(&contents, since_epoch));
    }

    for entry in history {
        // Untimed history entries cannot be attributed reliably once the
        // structured log has taken over.
        if has_log && entry.at.is_none() {
            continue;
        }
        if entries.iter().any(|logged| same_command(logged, &entry)) {
            continue;
        }
        entries.push(entry);
    }

    entries.sort_by(|left, right| match (&left.at, &right.at) {
        (Some(left), Some(right)) => left.cmp(right),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    });

    if entries.len() > limit {
        entries.drain(0..entries.len() - limit);
    }
    entries
}

#[derive(Debug, Deserialize)]
struct CommandLogRecord {
    ts_ms: i64,
    #[serde(default)]
    duration_ms: Option<u64>,
    #[serde(default)]
    exit_code: Option<i32>,
    #[serde(default)]
    tty: Option<String>,
    #[serde(default)]
    cwd: Option<String>,
    command: String,
}

fn command_log_path(user: &str) -> PathBuf {
    home_directory(user).join(".local/state/nixos-control/commands.jsonl")
}

fn read_command_log(user: &str, tty: Option<&str>, since_epoch: Option<i64>) -> Vec<HistoryEntry> {
    let Some(contents) = read_tail(&command_log_path(user)) else {
        return Vec::new();
    };
    parse_command_log(&contents, tty, since_epoch)
}

fn parse_command_log(
    contents: &str,
    tty: Option<&str>,
    since_epoch: Option<i64>,
) -> Vec<HistoryEntry> {
    let session_tty = tty.map(normalize_tty);
    let mut entries = Vec::new();
    for line in contents.lines() {
        let Ok(record) = serde_json::from_str::<CommandLogRecord>(line) else {
            continue;
        };
        if record.ts_ms <= 0 || record.command.trim().is_empty() {
            continue;
        }
        if let Some(since) = since_epoch {
            if record.ts_ms / 1000 < since - COMMAND_LOG_GRACE_SECONDS {
                continue;
            }
        }
        if let (Some(session_tty), Some(entry_tty)) = (&session_tty, record.tty.as_deref()) {
            if *session_tty != normalize_tty(entry_tty) {
                continue;
            }
        }

        let at = Utc
            .timestamp_millis_opt(record.ts_ms)
            .single()
            .map(|value| value.to_rfc3339_opts(SecondsFormat::Secs, true));
        let status = match record.exit_code {
            Some(0) => "ok",
            Some(_) => "failed",
            None => "unknown",
        };
        entries.push(HistoryEntry {
            at,
            command: record.command,
            duration_ms: record.duration_ms,
            exit_code: record.exit_code,
            status: status.to_string(),
            cwd: record.cwd.filter(|value| !value.is_empty()),
            source: "log".to_string(),
        });
    }
    entries
}

fn normalize_tty(tty: &str) -> String {
    tty.trim().trim_start_matches("/dev/").to_string()
}

fn same_command(left: &HistoryEntry, right: &HistoryEntry) -> bool {
    if left.command != right.command {
        return false;
    }
    match (parse_entry_time(left), parse_entry_time(right)) {
        (Some(left), Some(right)) => (left - right).num_seconds().abs() <= 3,
        _ => left.at.is_none() && right.at.is_none(),
    }
}

fn parse_entry_time(entry: &HistoryEntry) -> Option<DateTime<Utc>> {
    entry
        .at
        .as_deref()
        .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
        .map(|value| value.with_timezone(&Utc))
}

fn history_entry(at: Option<String>, command: String, duration_ms: Option<u64>) -> HistoryEntry {
    HistoryEntry {
        at,
        command,
        duration_ms,
        exit_code: None,
        status: "unknown".to_string(),
        cwd: None,
        source: "history".to_string(),
    }
}

fn home_directory(user: &str) -> PathBuf {
    if user == "root" {
        PathBuf::from("/root")
    } else if user.is_empty() || user.contains('/') || user == "." || user == ".." {
        PathBuf::from("/nonexistent")
    } else {
        PathBuf::from("/home").join(user)
    }
}

fn read_tail(path: &PathBuf) -> Option<String> {
    let mut file = File::open(path).ok()?;
    let length = file.metadata().ok()?.len();
    let start = length.saturating_sub(HISTORY_TAIL_BYTES);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).ok()?;
    let text = String::from_utf8_lossy(&bytes).into_owned();
    if start == 0 {
        return Some(text);
    }
    // Drop the first partial line when the file was tailed.
    Some(match text.find('\n') {
        Some(index) => text[index + 1..].to_string(),
        None => text,
    })
}

fn parse_zsh_history(contents: &str, since_epoch: Option<i64>) -> Vec<HistoryEntry> {
    let mut entries = Vec::new();
    for line in contents.lines() {
        let Some(rest) = line.strip_prefix(": ") else {
            let command = line.trim();
            if !command.is_empty() {
                entries.push(history_entry(None, command.to_string(), None));
            }
            continue;
        };
        let Some((meta, command)) = rest.split_once(';') else {
            continue;
        };
        let mut parts = meta.split(':');
        let started = parts
            .next()
            .and_then(|value| value.trim().parse::<i64>().ok());
        let elapsed = parts
            .next()
            .and_then(|value| value.trim().parse::<u64>().ok());
        let command = command.trim();
        if command.is_empty() {
            continue;
        }
        if let (Some(started), Some(since)) = (started, since_epoch) {
            if started < since {
                continue;
            }
        }
        entries.push(history_entry(
            started
                .and_then(|value| Utc.timestamp_opt(value, 0).single())
                .map(|value| value.to_rfc3339_opts(SecondsFormat::Secs, true)),
            command.to_string(),
            elapsed.map(|seconds| seconds * 1000),
        ));
    }
    entries
}

fn parse_bash_history(contents: &str, since_epoch: Option<i64>) -> Vec<HistoryEntry> {
    let mut entries = Vec::new();
    let mut pending: Option<i64> = None;
    for line in contents.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if let Some(value) = trimmed
            .strip_prefix('#')
            .and_then(|value| value.parse::<i64>().ok())
        {
            pending = Some(value);
            continue;
        }
        let at = pending.take();
        if let (Some(started), Some(since)) = (at, since_epoch) {
            if started < since {
                continue;
            }
        }
        entries.push(history_entry(
            at.and_then(|value| Utc.timestamp_opt(value, 0).single())
                .map(|value| value.to_rfc3339_opts(SecondsFormat::Secs, true)),
            trimmed.to_string(),
            None,
        ));
    }
    entries
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::CommandOutput;

    struct SessionRunner;

    impl CommandRunner for SessionRunner {
        fn run(&self, program: &str, args: &[&str], _timeout: Duration) -> CommandOutput {
            match (program, args.first().copied()) {
                ("loginctl", Some("list-sessions")) => CommandOutput::success(
                    "  2 1000 oliver seat0 1234 user tty1 no -\nc1 1001 guest - 1235 user - no -\n",
                ),
                ("loginctl", Some("show-session")) if args.contains(&"Timestamp") => {
                    CommandOutput::success("1763852400000000\n")
                }
                ("loginctl", Some("show-session")) => {
                    if args.get(1) == Some(&"2") {
                        CommandOutput::success(
                            "Id=2\nName=oliver\nRemote=no\nService=login\nType=tty\nClass=user\nState=active\nTTY=tty1\nSeat=seat0\nActive=yes\n",
                        )
                    } else {
                        CommandOutput::success(
                            "Id=c1\nName=guest\nRemote=yes\nRemoteHost=192.168.1.20\nService=sshd\nType=tty\nClass=user\nState=active\nTTY=-\nSeat=seat0\nActive=yes\n",
                        )
                    }
                }
                ("journalctl", Some(match_value)) if match_value.contains("_SYSTEMD_SESSION=2") => {
                    CommandOutput::success("2026-01-01T00:00:00+0000 host login[1]: hello\n")
                }
                ("journalctl", _) => CommandOutput::success(""),
                _ => CommandOutput::failure("", "unexpected command"),
            }
        }

        fn exists(&self, _program: &str) -> bool {
            true
        }
    }

    #[test]
    fn parses_logind_sessions() {
        let sessions = collect_login_sessions(&SessionRunner);
        assert_eq!(sessions.len(), 2);
        let console = sessions.iter().find(|session| session.id == "2").unwrap();
        assert_eq!(console.user, "oliver");
        assert_eq!(console.tty.as_deref(), Some("tty1"));
        assert!(!console.remote);
        assert!(console.started_at.starts_with("2025-11-22"));
        let ssh = sessions.iter().find(|session| session.id == "c1").unwrap();
        assert!(ssh.remote);
        assert_eq!(ssh.remote_host.as_deref(), Some("192.168.1.20"));
        assert_eq!(ssh.service, "sshd");
    }

    #[test]
    fn reads_session_journal() {
        let lines = session_logs(&SessionRunner, "2", 50).unwrap();
        assert_eq!(lines.len(), 1);
        assert!(lines[0].contains("hello"));
    }

    #[test]
    fn parses_zsh_and_bash_history() {
        let zsh = ": 1763852400:0;git status\n: 1763852500:3;nixos-rebuild switch\n";
        let entries = parse_zsh_history(zsh, Some(1763852450));
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].command, "nixos-rebuild switch");
        assert!(entries[0].at.is_some());
        assert_eq!(entries[0].duration_ms, Some(3000));
        assert_eq!(entries[0].status, "unknown");
        assert_eq!(entries[0].source, "history");

        let bash = "#1763852400\nls -la\n#1763852500\nmake test\n";
        let entries = parse_bash_history(bash, Some(1763852450));
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].command, "make test");
        assert!(entries[0].at.is_some());
        assert_eq!(entries[0].duration_ms, None);
        assert_eq!(entries[0].exit_code, None);
        assert_eq!(entries[0].source, "history");
    }

    #[test]
    fn parses_the_shell_command_audit_log() {
        let log = concat!(
            r#"{"ts_ms":1763852500000,"duration_ms":1250,"exit_code":0,"tty":"pts/2","cwd":"/etc/nixos","command":"nixos-rebuild switch"}"#,
            "\n",
            r#"{"ts_ms":1763852510000,"duration_ms":20,"exit_code":1,"tty":"/dev/pts/2","cwd":"/tmp","command":"false"}"#,
            "\n",
            r#"{"ts_ms":1763852520000,"duration_ms":5,"exit_code":0,"tty":"pts/3","cwd":"/tmp","command":"ls"}"#,
            "\n",
            "not json\n",
        );

        let entries = parse_command_log(log, Some("pts/2"), Some(1763852400));
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].command, "nixos-rebuild switch");
        assert_eq!(entries[0].status, "ok");
        assert_eq!(entries[0].exit_code, Some(0));
        assert_eq!(entries[0].duration_ms, Some(1250));
        assert_eq!(entries[0].cwd.as_deref(), Some("/etc/nixos"));
        assert_eq!(entries[0].source, "log");
        assert!(entries[0].at.as_deref().unwrap().starts_with("2025-11-22"));

        assert_eq!(entries[1].command, "false");
        assert_eq!(entries[1].status, "failed");
        assert_eq!(entries[1].exit_code, Some(1));

        let older = parse_command_log(log, Some("pts/2"), Some(1763852515));
        assert_eq!(older.len(), 1);
        assert_eq!(older[0].command, "false");
    }

    #[test]
    fn tty_comparison_ignores_the_dev_prefix() {
        assert_eq!(normalize_tty("/dev/pts/2"), "pts/2");
        assert_eq!(normalize_tty(" pts/2 "), "pts/2");
    }

    #[test]
    fn rejects_unsafe_session_ids() {
        assert!(session_logs(&SessionRunner, "2; rm -rf /", 10).is_err());
    }
}
