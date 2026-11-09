use std::time::Duration;

use crate::commands::CommandRunner;
use crate::models::{ServiceCounts, ServiceUnit};
use crate::util::split_lines;

pub fn collect_service_units(runner: &dyn CommandRunner) -> Vec<ServiceUnit> {
    let result = runner.run(
        "systemctl",
        &[
            "list-units",
            "--type=service",
            "--all",
            "--output=json",
            "--no-pager",
        ],
        Duration::from_secs(10),
    );

    if result.error.is_none() {
        if result.output.trim() == "null" {
            return Vec::new();
        }
        if let Ok(units) = serde_json::from_str::<Vec<ServiceUnit>>(&result.output) {
            return units;
        }
    }

    // Fallback for systemd versions without JSON output.
    let result = runner.run(
        "systemctl",
        &[
            "list-units",
            "--type=service",
            "--all",
            "--no-legend",
            "--plain",
            "--no-pager",
        ],
        Duration::from_secs(10),
    );
    if result.error.is_some() && result.output.trim().is_empty() {
        return Vec::new();
    }
    parse_plain_units(&result.output)
}

pub fn parse_plain_units(output: &str) -> Vec<ServiceUnit> {
    let mut units = Vec::new();
    for line in split_lines(output) {
        let mut fields: Vec<&str> = line.split_whitespace().collect();
        if fields.first() == Some(&"●") {
            fields.remove(0);
        }
        if fields.len() < 4 || !fields[0].ends_with(".service") {
            continue;
        }
        let description = if fields.len() > 4 {
            fields[4..].join(" ")
        } else {
            String::new()
        };
        units.push(ServiceUnit {
            unit: fields[0].to_string(),
            load: fields[1].to_string(),
            active: fields[2].to_string(),
            sub: fields[3].to_string(),
            description,
        });
    }
    units
}

pub fn collect_service_counts(runner: &dyn CommandRunner) -> ServiceCounts {
    let result = runner.run(
        "systemctl",
        &[
            "list-units",
            "--type=service",
            "--all",
            "--no-legend",
            "--plain",
            "--no-pager",
        ],
        Duration::from_secs(10),
    );
    if result.error.is_some() && result.output.trim().is_empty() {
        return ServiceCounts::default();
    }
    parse_service_counts(&result.output)
}

pub fn parse_service_counts(output: &str) -> ServiceCounts {
    let mut counts = ServiceCounts::default();
    for line in split_lines(output) {
        let mut fields: Vec<&str> = line.split_whitespace().collect();
        if fields.first() == Some(&"●") {
            fields.remove(0);
        }
        if fields.len() < 3 || !fields[0].ends_with(".service") {
            continue;
        }
        counts.total += 1;
        match fields[2] {
            "active" => counts.running += 1,
            "failed" => counts.failed += 1,
            _ => {}
        }
    }
    counts
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::CommandOutput;

    #[test]
    fn parses_plain_systemctl_units() {
        let output = "\
nginx.service        loaded active running A high performance web server
● broken.service     loaded failed failed  Broken unit
ignored.socket       loaded active running A socket
short line
";
        let units = parse_plain_units(output);
        assert_eq!(units.len(), 2);
        assert_eq!(units[0].unit, "nginx.service");
        assert_eq!(units[0].load, "loaded");
        assert_eq!(units[0].active, "active");
        assert_eq!(units[0].sub, "running");
        assert_eq!(units[0].description, "A high performance web server");
        assert_eq!(units[1].unit, "broken.service");
        assert_eq!(units[1].active, "failed");
    }

    #[test]
    fn counts_active_and_failed_units() {
        let output = "\
nginx.service loaded active running web
db.service loaded failed failed database
idle.service loaded inactive dead idle
● down.service loaded failed failed down
";
        let counts = parse_service_counts(output);
        assert_eq!(counts.total, 4);
        assert_eq!(counts.running, 1);
        assert_eq!(counts.failed, 2);
    }

    #[test]
    fn json_output_is_preferred() {
        struct JsonRunner;
        impl CommandRunner for JsonRunner {
            fn run(&self, _program: &str, _args: &[&str], _timeout: Duration) -> CommandOutput {
                CommandOutput::success(
                    r#"[{"unit":"nginx.service","load":"loaded","active":"active","sub":"running","description":"web"}]"#,
                )
            }
            fn exists(&self, _program: &str) -> bool {
                true
            }
        }

        let units = collect_service_units(&JsonRunner);
        assert_eq!(units.len(), 1);
        assert_eq!(units[0].unit, "nginx.service");
        assert_eq!(units[0].description, "web");
    }

    #[test]
    fn falls_back_to_plain_output() {
        struct PlainRunner;
        impl CommandRunner for PlainRunner {
            fn run(&self, _program: &str, args: &[&str], _timeout: Duration) -> CommandOutput {
                if args.contains(&"--output=json") {
                    CommandOutput::failure("", "unknown flag")
                } else {
                    CommandOutput::success("nginx.service loaded active running web\n")
                }
            }
            fn exists(&self, _program: &str) -> bool {
                true
            }
        }

        let units = collect_service_units(&PlainRunner);
        assert_eq!(units.len(), 1);
        assert_eq!(units[0].unit, "nginx.service");
    }

    #[test]
    fn empty_output_produces_empty_results() {
        struct FailingRunner;
        impl CommandRunner for FailingRunner {
            fn run(&self, _program: &str, _args: &[&str], _timeout: Duration) -> CommandOutput {
                CommandOutput::failure("", "boom")
            }
            fn exists(&self, _program: &str) -> bool {
                false
            }
        }

        assert!(collect_service_units(&FailingRunner).is_empty());
        assert_eq!(
            collect_service_counts(&FailingRunner),
            ServiceCounts::default()
        );
    }
}
