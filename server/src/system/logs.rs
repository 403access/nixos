use std::time::Duration;

use chrono::{SecondsFormat, TimeZone, Utc};
use serde_json::Value;

use crate::commands::CommandRunner;
use crate::models::{LogEntry, LogsResponse};
use crate::util::split_lines;

const LOG_TIMEOUT: Duration = Duration::from_secs(20);

/// Read the system journal as structured entries.
pub fn system_logs(runner: &dyn CommandRunner, lines: usize) -> Result<LogsResponse, String> {
    journal(runner, &[], lines)
}

/// Read one unit's journal as structured entries.
pub fn service_logs(
    runner: &dyn CommandRunner,
    unit: &str,
    lines: usize,
) -> Result<LogsResponse, String> {
    journal(runner, &["-u", unit], lines)
}

fn journal(
    runner: &dyn CommandRunner,
    filters: &[&str],
    lines: usize,
) -> Result<LogsResponse, String> {
    let count = lines.to_string();
    let mut args: Vec<String> = filters.iter().map(|value| value.to_string()).collect();
    args.extend([
        "-n".to_string(),
        count,
        "--no-pager".to_string(),
        "-o".to_string(),
        "json".to_string(),
    ]);
    let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();

    let result = runner.run("journalctl", &arg_refs, LOG_TIMEOUT);
    if let Some(error) = result.error {
        if result.output.trim().is_empty() {
            return Err(error);
        }
        log::warn!("journalctl reported an error: {error}");
    }

    let entries = parse_json_entries(&result.output);
    if entries.is_empty() {
        let raw = split_lines(&result.output);
        return Ok(LogsResponse {
            lines: raw,
            entries: Vec::new(),
        });
    }

    let lines = entries.iter().map(format_line).collect();
    Ok(LogsResponse { lines, entries })
}

/// Parse `journalctl -o json` output. Each line is an independent JSON object.
pub fn parse_json_entries(output: &str) -> Vec<LogEntry> {
    let mut entries = Vec::new();
    for line in output.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if let Some(entry) = parse_entry(&value) {
            entries.push(entry);
        }
    }
    entries
}

fn parse_entry(value: &Value) -> Option<LogEntry> {
    let message = text_field(value, "MESSAGE").unwrap_or_else(|| "(no message)".to_string());
    let priority = value
        .get("PRIORITY")
        .and_then(json_text)
        .and_then(|value| value.parse::<u8>().ok())
        .unwrap_or(6)
        .min(7);

    Some(LogEntry {
        timestamp: timestamp(value),
        priority,
        level: level_name(priority).to_string(),
        message,
        identifier: text_field(value, "SYSLOG_IDENTIFIER").or_else(|| text_field(value, "_COMM")),
        unit: text_field(value, "_SYSTEMD_USER_UNIT")
            .or_else(|| text_field(value, "_SYSTEMD_UNIT")),
        pid: text_field(value, "_PID")
            .or_else(|| text_field(value, "SYSLOG_PID"))
            .and_then(|value| value.parse::<i32>().ok()),
        hostname: text_field(value, "_HOSTNAME"),
        transport: text_field(value, "_TRANSPORT"),
        comm: text_field(value, "_COMM"),
        exe: text_field(value, "_EXE"),
    })
}

fn timestamp(value: &Value) -> String {
    let Some(micros) = value
        .get("__REALTIME_TIMESTAMP")
        .and_then(json_text)
        .and_then(|value| value.parse::<i64>().ok())
    else {
        return String::new();
    };
    let seconds = micros.div_euclid(1_000_000);
    let nanos = (micros.rem_euclid(1_000_000) * 1_000) as u32;
    Utc.timestamp_opt(seconds, nanos)
        .single()
        .map(|value| value.to_rfc3339_opts(SecondsFormat::Secs, true))
        .unwrap_or_default()
}

fn text_field(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(json_text)
}

fn json_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Array(items) => {
            let bytes: Vec<u8> = items
                .iter()
                .filter_map(|item| item.as_u64())
                .filter(|value| *value <= 255)
                .map(|value| value as u8)
                .collect();
            if bytes.is_empty() {
                None
            } else {
                Some(String::from_utf8_lossy(&bytes).into_owned())
            }
        }
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

pub fn level_name(priority: u8) -> &'static str {
    match priority {
        0 => "emerg",
        1 => "alert",
        2 => "crit",
        3 => "err",
        4 => "warning",
        5 => "notice",
        6 => "info",
        _ => "debug",
    }
}

fn format_line(entry: &LogEntry) -> String {
    let timestamp = if entry.timestamp.is_empty() {
        "?".to_string()
    } else {
        entry.timestamp.clone()
    };
    let source = match (&entry.identifier, entry.pid) {
        (Some(identifier), Some(pid)) => format!("{identifier}[{pid}]"),
        (Some(identifier), None) => identifier.clone(),
        (None, Some(pid)) => format!("pid {pid}"),
        (None, None) => entry.unit.clone().unwrap_or_else(|| "journal".to_string()),
    };
    format!(
        "{} {} {}: {}",
        timestamp, entry.level, source, entry.message
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_structured_journal_entries() {
        let output = concat!(
            r#"{"__REALTIME_TIMESTAMP":"1763852400000000","PRIORITY":"3","MESSAGE":"unit failed","SYSLOG_IDENTIFIER":"nginx","_PID":"123","_HOSTNAME":"nixos","_TRANSPORT":"stdout","_SYSTEMD_UNIT":"nginx.service","_COMM":"nginx","_EXE":"/nix/store/nginx/bin/nginx"}"#,
            "\n",
            r#"{"__REALTIME_TIMESTAMP":"1763852401000000","PRIORITY":"6","MESSAGE":[104,101,108,108,111],"SYSLOG_IDENTIFIER":"bun","_PID":"456","_SYSTEMD_USER_UNIT":"nixos-control-web.service"}"#,
            "\n",
        );
        let entries = parse_json_entries(output);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].level, "err");
        assert_eq!(entries[0].priority, 3);
        assert_eq!(entries[0].message, "unit failed");
        assert_eq!(entries[0].unit.as_deref(), Some("nginx.service"));
        assert_eq!(entries[0].pid, Some(123));
        assert_eq!(entries[0].timestamp, "2025-11-22T23:00:00Z");
        assert_eq!(entries[1].level, "info");
        assert_eq!(entries[1].message, "hello");
        assert_eq!(
            entries[1].unit.as_deref(),
            Some("nixos-control-web.service")
        );
    }

    #[test]
    fn malformed_lines_are_skipped() {
        let entries = parse_json_entries("not json\n{\"MESSAGE\":\"ok\"}\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].message, "ok");
        assert_eq!(entries[0].level, "info");
    }

    #[test]
    fn formats_human_readable_lines() {
        let entry = LogEntry {
            timestamp: "2025-11-22T23:00:00Z".to_string(),
            priority: 4,
            level: "warning".to_string(),
            message: "disk almost full".to_string(),
            identifier: Some("zfs".to_string()),
            pid: Some(42),
            ..LogEntry::default()
        };
        assert_eq!(
            format_line(&entry),
            "2025-11-22T23:00:00Z warning zfs[42]: disk almost full"
        );
    }
}
