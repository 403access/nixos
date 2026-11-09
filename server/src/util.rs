use std::fs;
use std::path::Path;
use std::sync::OnceLock;

use regex::Regex;
use subtle::ConstantTimeEq;

/// Read a file and trim surrounding whitespace, returning an empty string when
/// the file does not exist or cannot be read. This mirrors `readFileTrim` in
/// the archived Go server.
pub fn read_file_trim(path: impl AsRef<Path>) -> String {
    fs::read_to_string(path)
        .map(|value| value.trim().to_string())
        .unwrap_or_default()
}

/// Split output into lines. A trailing newline is ignored and whitespace-only
/// input produces an empty vector.
pub fn split_lines(value: &str) -> Vec<String> {
    let trimmed = value.trim_end_matches('\n');
    if trimmed.trim().is_empty() {
        return Vec::new();
    }
    trimmed.split('\n').map(str::to_string).collect()
}

pub fn parse_i64(value: &str) -> i64 {
    value.trim().parse::<i64>().unwrap_or(0)
}

pub fn parse_u64(value: &str) -> u64 {
    value.trim().parse::<u64>().unwrap_or(0)
}

pub fn parse_f64(value: &str) -> f64 {
    value.trim().parse::<f64>().unwrap_or(0.0)
}

/// Remove matching quotes from a value, handling JSON-style escapes for double
/// quoted values. This is the subset of `strconv.Unquote` used for
/// `/etc/os-release`.
pub fn unquote(value: &str) -> String {
    let value = value.trim();
    let bytes = value.as_bytes();
    if bytes.len() >= 2 {
        let first = bytes[0];
        let last = bytes[bytes.len() - 1];
        if first == b'"' && last == b'"' {
            if let Ok(unquoted) = serde_json::from_str::<String>(value) {
                return unquoted;
            }
            return value[1..value.len() - 1].to_string();
        }
        if first == b'\'' && last == b'\'' {
            return value[1..value.len() - 1].to_string();
        }
    }
    value.to_string()
}

/// Constant-time bearer-token comparison. An empty expected token is never
/// valid.
pub fn valid_token(got: &str, expected: &str) -> bool {
    if expected.is_empty() {
        return false;
    }
    got.as_bytes().ct_eq(expected.as_bytes()).into()
}

fn unit_name_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"^[A-Za-z0-9@_][A-Za-z0-9@_.:\\-]*\.service$").expect("valid unit regex")
    })
}

fn pool_name_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^[A-Za-z0-9_][A-Za-z0-9_.:-]*$").expect("valid pool regex"))
}

pub fn valid_unit_name(name: &str) -> bool {
    unit_name_re().is_match(name)
}

pub fn valid_pool_name(name: &str) -> bool {
    pool_name_re().is_match(name)
}

pub fn round1(value: f64) -> f64 {
    (value * 10.0).round() / 10.0
}

fn ansi_escape_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\x1b\[[0-9;?]*[ -/]*[@-~]").expect("valid ANSI escape regex"))
}

pub fn strip_ansi(value: &str) -> String {
    ansi_escape_re().replace_all(value, "").into_owned()
}

/// Format a duration the way the Go server published timeouts, for example
/// `45 minutes`.
pub fn human_duration(duration: std::time::Duration) -> String {
    let seconds = duration.as_secs();
    if seconds == 0 {
        let millis = duration.as_millis();
        return format!("{millis} milliseconds");
    }
    if seconds.is_multiple_of(60) {
        let minutes = seconds / 60;
        if minutes.is_multiple_of(60) {
            let hours = minutes / 60;
            return format!("{hours} {}", plural(hours, "hour"));
        }
        return format!("{minutes} {}", plural(minutes, "minute"));
    }
    format!("{seconds} {}", plural(seconds, "second"))
}

fn plural(value: u64, unit: &str) -> String {
    if value == 1 {
        unit.to_string()
    } else {
        format!("{unit}s")
    }
}

/// Parse the `lines` query parameter with the same fallback and clamping rules
/// as the Go server: invalid or non-positive values use the fallback, values
/// below 10 become 10, and values above 2000 become 2000.
pub fn parse_lines_param(value: &str, fallback: usize) -> usize {
    let lines = parse_i64(value);
    if lines <= 0 {
        return fallback;
    }
    let lines = lines as usize;
    if lines < 10 {
        return 10;
    }
    if lines > 2000 {
        return 2000;
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_lines_ignores_trailing_newline_and_blank_input() {
        assert_eq!(split_lines("a\nb\n"), vec!["a", "b"]);
        assert!(split_lines("  \n\t").is_empty());
        assert_eq!(split_lines("a\n\nb"), vec!["a", "", "b"]);
    }

    #[test]
    fn numeric_parsers_use_zero_for_invalid_values() {
        assert_eq!(parse_i64(" 42 "), 42);
        assert_eq!(parse_i64("nope"), 0);
        assert_eq!(parse_u64("7"), 7);
        assert_eq!(parse_u64("-1"), 0);
        assert_eq!(parse_f64(" 0.52 "), 0.52);
        assert_eq!(parse_f64("nope"), 0.0);
    }

    #[test]
    fn unquote_handles_double_single_and_unquoted_values() {
        assert_eq!(
            unquote("\"NixOS 25.05 (Xantusia)\""),
            "NixOS 25.05 (Xantusia)"
        );
        assert_eq!(unquote("'value'"), "value");
        assert_eq!(unquote("plain"), "plain");
        assert_eq!(unquote("\"tab\\there\""), "tab\there");
    }

    #[test]
    fn token_comparison_matches_go_behaviour() {
        assert!(valid_token("secret", "secret"));
        assert!(!valid_token("secret", "other"));
        assert!(!valid_token("", ""));
        assert!(!valid_token("secret", ""));
        assert!(!valid_token("", "secret"));
    }

    #[test]
    fn unit_names_accept_systemd_units_and_reject_paths() {
        let valid = [
            "nginx.service",
            "getty@tty1.service",
            "docker.service",
            "systemd-networkd.service",
            "systemd-fsck@dev-disk-by\\x2duuid-1234.service",
            "foo:bar.service",
        ];
        for name in valid {
            assert!(valid_unit_name(name), "expected {name:?} to be valid");
        }

        let invalid = [
            "nginx",
            "../../etc/passwd",
            "--help.service",
            "nginx.socket",
            "foo bar.service",
            "",
            ".service",
            "foo/service.service",
        ];
        for name in invalid {
            assert!(!valid_unit_name(name), "expected {name:?} to be invalid");
        }
    }

    #[test]
    fn pool_names_accept_zfs_names_and_reject_paths() {
        for name in ["tank", "tank-data", "pool-1", "a_b:c"] {
            assert!(valid_pool_name(name), "expected {name:?} to be valid");
        }
        for name in ["", "-pool", "../tank", "tank/data", "tank data", "/tank"] {
            assert!(!valid_pool_name(name), "expected {name:?} to be invalid");
        }
    }

    #[test]
    fn lines_param_is_clamped_like_go() {
        assert_eq!(parse_lines_param("", 200), 200);
        assert_eq!(parse_lines_param("0", 200), 200);
        assert_eq!(parse_lines_param("-5", 200), 200);
        assert_eq!(parse_lines_param("not-a-number", 300), 300);
        assert_eq!(parse_lines_param("1", 200), 10);
        assert_eq!(parse_lines_param("9", 200), 10);
        assert_eq!(parse_lines_param("10", 200), 10);
        assert_eq!(parse_lines_param("250", 200), 250);
        assert_eq!(parse_lines_param("99999", 200), 2000);
    }

    #[test]
    fn ansi_escapes_are_removed() {
        assert_eq!(strip_ansi("\x1b[31mred\x1b[0m"), "red");
        assert_eq!(strip_ansi("plain"), "plain");
    }

    #[test]
    fn round1_matches_go_rounding() {
        assert_eq!(round1(12.34), 12.3);
        assert_eq!(round1(12.35), 12.4);
        assert_eq!(round1(99.99), 100.0);
    }

    #[test]
    fn human_duration_matches_timeout_copy() {
        use std::time::Duration;
        assert_eq!(human_duration(Duration::from_secs(45 * 60)), "45 minutes");
        assert_eq!(human_duration(Duration::from_secs(2 * 60 * 60)), "2 hours");
        assert_eq!(human_duration(Duration::from_secs(5)), "5 seconds");
    }
}
