use std::path::Path;
use std::sync::OnceLock;
use std::time::Duration;

use chrono::{DateTime, Local};
use regex::Regex;

use crate::commands::CommandRunner;
use crate::models::Generation;
use crate::util::split_lines;

use super::SystemPaths;

fn generation_link_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"system-(\d+)-link").expect("valid generation link regex"))
}

fn generation_line_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"^\s*(\d+)\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(.*)$")
            .expect("valid generation line regex")
    })
}

pub fn collect_generations(runner: &dyn CommandRunner, paths: &SystemPaths) -> Vec<Generation> {
    let profile = paths.nix_profiles.join("system");
    let profile = profile.to_string_lossy().into_owned();
    let result = runner.run(
        "nix-env",
        &["--list-generations", "--profile", &profile],
        Duration::from_secs(8),
    );
    if result.error.is_none() {
        let generations = parse_generations_output(&result.output);
        if !generations.is_empty() {
            return generations;
        }
    }

    let current = read_generation(paths);
    let mut generations = Vec::new();
    let pattern = format!("{}/system-*-link", paths.nix_profiles.display());
    let Ok(entries) = glob::glob(&pattern) else {
        return generations;
    };

    for entry in entries.flatten() {
        let base = entry
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let Some(captures) = generation_link_re().captures(&base) else {
            continue;
        };
        let number = captures
            .get(1)
            .and_then(|value| value.as_str().parse::<i32>().ok())
            .unwrap_or(0);
        let date = std::fs::metadata(&entry)
            .and_then(|metadata| metadata.modified())
            .map(|modified| {
                let datetime: DateTime<Local> = modified.into();
                datetime.format("%Y-%m-%d %H:%M:%S").to_string()
            })
            .unwrap_or_default();

        generations.push(Generation {
            number,
            date,
            current: number == current,
        });
    }

    generations.sort_by_key(|generation| generation.number);
    generations
}

pub fn parse_generations_output(output: &str) -> Vec<Generation> {
    let mut generations = Vec::new();
    for line in split_lines(output) {
        let Some(captures) = generation_line_re().captures(&line) else {
            continue;
        };
        let number = captures
            .get(1)
            .and_then(|value| value.as_str().parse::<i32>().ok())
            .unwrap_or(0);
        let date = captures
            .get(2)
            .map(|value| value.as_str().to_string())
            .unwrap_or_default();
        let suffix = captures
            .get(3)
            .map(|value| value.as_str().to_lowercase())
            .unwrap_or_default();
        generations.push(Generation {
            number,
            date,
            current: suffix.contains("current"),
        });
    }
    generations
}

pub fn read_generation(paths: &SystemPaths) -> i32 {
    let link = paths.nix_profiles.join("system");
    let target = match std::fs::read_link(link) {
        Ok(target) => target,
        Err(_) => return 0,
    };
    let target = target.to_string_lossy();
    generation_link_re()
        .captures(&target)
        .and_then(|captures| captures.get(1))
        .and_then(|value| value.as_str().parse::<i32>().ok())
        .unwrap_or(0)
}

pub fn read_generation_at(link: &Path) -> i32 {
    let Ok(target) = std::fs::read_link(link) else {
        return 0;
    };
    let target = target.to_string_lossy();
    generation_link_re()
        .captures(&target)
        .and_then(|captures| captures.get(1))
        .and_then(|value| value.as_str().parse::<i32>().ok())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::CommandOutput;

    fn fixture_paths(directory: &Path) -> SystemPaths {
        SystemPaths {
            proc_dir: directory.join("proc"),
            sys_dir: directory.join("sys"),
            etc_dir: directory.join("etc"),
            run_dir: directory.join("run"),
            nix_profiles: directory.join("nix/var/nix/profiles"),
        }
    }

    struct NoNixEnv;
    impl CommandRunner for NoNixEnv {
        fn run(&self, _program: &str, _args: &[&str], _timeout: Duration) -> CommandOutput {
            CommandOutput::failure("", "not found")
        }
        fn exists(&self, _program: &str) -> bool {
            false
        }
    }

    #[test]
    fn parses_generation_listing() {
        let output = "\
   1   2024-01-01 10:00:00
   2   2024-02-01 11:30:00
   3   2024-03-01 12:45:00   (current)
";
        let generations = parse_generations_output(output);
        assert_eq!(generations.len(), 3);
        assert_eq!(generations[2].number, 3);
        assert!(generations[2].current);
        assert_eq!(generations[0].date, "2024-01-01 10:00:00");
        assert!(!generations[0].current);
    }

    #[test]
    fn malformed_generation_lines_are_ignored() {
        assert!(parse_generations_output("not a generation\n3 oops\n").is_empty());
    }

    #[test]
    fn falls_back_to_profile_links() {
        let directory = tempfile::tempdir().expect("tempdir");
        let paths = fixture_paths(directory.path());
        std::fs::create_dir_all(&paths.nix_profiles).unwrap();

        let target_one = paths.nix_profiles.join("target-one");
        let target_two = paths.nix_profiles.join("target-two");
        std::fs::write(&target_one, "").unwrap();
        std::fs::write(&target_two, "").unwrap();
        std::os::unix::fs::symlink(&target_one, paths.nix_profiles.join("system-1-link")).unwrap();
        std::os::unix::fs::symlink(&target_two, paths.nix_profiles.join("system-2-link")).unwrap();
        std::os::unix::fs::symlink("system-2-link", paths.nix_profiles.join("system")).unwrap();

        let generations = collect_generations(&NoNixEnv, &paths);
        assert_eq!(generations.len(), 2);
        assert_eq!(generations[0].number, 1);
        assert_eq!(generations[1].number, 2);
        assert!(!generations[0].current);
        assert!(generations[1].current);
        assert!(!generations[1].date.is_empty());
        assert_eq!(read_generation(&paths), 2);
    }

    #[test]
    fn missing_profile_returns_no_generations() {
        let directory = tempfile::tempdir().expect("tempdir");
        let paths = fixture_paths(directory.path());
        assert!(collect_generations(&NoNixEnv, &paths).is_empty());
        assert_eq!(read_generation(&paths), 0);
    }

    #[test]
    fn nix_env_output_wins_when_available() {
        struct WithNixEnv;
        impl CommandRunner for WithNixEnv {
            fn run(&self, _program: &str, _args: &[&str], _timeout: Duration) -> CommandOutput {
                CommandOutput::success("  7  2024-07-01 10:00:00   (current)\n")
            }
            fn exists(&self, _program: &str) -> bool {
                true
            }
        }

        let directory = tempfile::tempdir().expect("tempdir");
        let paths = fixture_paths(directory.path());
        let generations = collect_generations(&WithNixEnv, &paths);
        assert_eq!(generations.len(), 1);
        assert_eq!(generations[0].number, 7);
        assert!(generations[0].current);
    }
}
