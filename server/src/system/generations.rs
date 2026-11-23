use std::path::Path;
use std::sync::OnceLock;
use std::time::Duration;

use chrono::{DateTime, Local};
use regex::Regex;

use crate::commands::CommandRunner;
use crate::models::{Generation, GenerationDiff, GenerationDiffEntry};
use crate::util::{split_lines, strip_ansi};

use super::SystemPaths;

const DIFF_LINE_LIMIT: usize = 2000;
const DIFF_TIMEOUT: Duration = Duration::from_secs(60);

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

fn generation_link(paths: &SystemPaths, number: i32) -> Result<String, String> {
    let link = paths.nix_profiles.join(format!("system-{number}-link"));
    match std::fs::symlink_metadata(&link) {
        Ok(_) => Ok(link.to_string_lossy().into_owned()),
        Err(_) => Err(format!("generation {number} is not available")),
    }
}

/// Compare the package closures of two NixOS generations with
/// `nix store diff-closures`. This is the same package-level diff that
/// `nixos-rebuild` reports before activating a configuration.
pub fn diff_generations(
    runner: &dyn CommandRunner,
    paths: &SystemPaths,
    from: i32,
    to: i32,
) -> Result<GenerationDiff, String> {
    if from <= 0 || to <= 0 {
        return Err("generation numbers must be positive".to_string());
    }
    if from == to {
        return Ok(GenerationDiff {
            from,
            to,
            ..GenerationDiff::default()
        });
    }

    let from_link = generation_link(paths, from)?;
    let to_link = generation_link(paths, to)?;

    if !runner.exists("nix") {
        return Err("nix is not available on this system".to_string());
    }

    let result = runner.run(
        "nix",
        &[
            "--extra-experimental-features",
            "nix-command",
            "store",
            "diff-closures",
            &from_link,
            &to_link,
        ],
        DIFF_TIMEOUT,
    );

    if let Some(error) = result.error {
        if result.output.trim().is_empty() {
            return Err(error);
        }
        log::warn!("nix store diff-closures reported an error: {error}");
    }

    let raw_lines = split_lines(&result.output);
    let truncated = raw_lines.len() > DIFF_LINE_LIMIT;
    let lines: Vec<String> = raw_lines
        .iter()
        .take(DIFF_LINE_LIMIT)
        .map(|line| strip_ansi(line))
        .filter(|line| !line.trim().is_empty())
        .collect();
    let entries: Vec<GenerationDiffEntry> = lines
        .iter()
        .filter_map(|line| parse_diff_line(line))
        .collect();

    let added = entries
        .iter()
        .filter(|entry| entry.change == "added")
        .count();
    let removed = entries
        .iter()
        .filter(|entry| entry.change == "removed")
        .count();
    let changed = entries
        .iter()
        .filter(|entry| entry.change == "changed")
        .count();

    Ok(GenerationDiff {
        from,
        to,
        entries,
        lines,
        added,
        removed,
        changed,
        truncated,
    })
}

/// Parse one line of `nix store diff-closures` output. Unknown lines are kept
/// in the raw output but do not produce a structured entry.
pub fn parse_diff_line(line: &str) -> Option<GenerationDiffEntry> {
    let line = line.trim();
    let (name, rest) = line.split_once(": ")?;
    let name = name.trim();
    if name.is_empty() {
        return None;
    }

    let mut rest = rest.trim();
    let mut size = None;
    if let Some((head, tail)) = rest.rsplit_once(", ") {
        let candidate = tail.trim();
        if (candidate.starts_with('+') || candidate.starts_with('-'))
            && candidate
                .chars()
                .any(|character| character.is_ascii_alphabetic())
        {
            size = Some(candidate.to_string());
            rest = head.trim();
        }
    } else if (rest.starts_with('+') || rest.starts_with('-'))
        && rest
            .chars()
            .any(|character| character.is_ascii_alphabetic())
    {
        // A size-only change, for example `nixos-control: +280.9 KiB`.
        size = Some(rest.to_string());
        rest = "";
    }

    let (before_raw, after_raw) = match rest.split_once(" → ") {
        Some((before, after)) => (Some(before.trim()), Some(after.trim())),
        None => (None, None),
    };

    let normalize = |value: Option<&str>| match value {
        None | Some("") | Some("∅") | Some("ε") => None,
        Some(value) => Some(value.to_string()),
    };
    let before = normalize(before_raw);
    let after = normalize(after_raw);

    let change = match (&before, &after, after_raw) {
        // `∅ → ε` is an added package with an empty version string.
        (None, None, Some(_)) => "added",
        (None, Some(_), _) => "added",
        (Some(_), None, _) => "removed",
        (Some(_), Some(_), _) => "changed",
        // Size-only changes have no version arrow.
        (None, None, None) => "changed",
    };

    Some(GenerationDiffEntry {
        name: name.to_string(),
        change: change.to_string(),
        before,
        after,
        size,
        line: line.to_string(),
    })
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

    #[test]
    fn parses_closure_diff_lines() {
        let added = parse_diff_line("desktop-xrandr: ∅ → ε").unwrap();
        assert_eq!(added.change, "added");
        assert_eq!(added.before, None);
        assert_eq!(added.after, None);

        let removed = parse_diff_line("kdeconnect: 20.08.2 → ∅, -6597.8 KiB").unwrap();
        assert_eq!(removed.change, "removed");
        assert_eq!(removed.before.as_deref(), Some("20.08.2"));
        assert_eq!(removed.after, None);
        assert_eq!(removed.size.as_deref(), Some("-6597.8 KiB"));

        let changed = parse_diff_line("glibc: 2.39-52 → 2.39-66, +12.0 KiB").unwrap();
        assert_eq!(changed.change, "changed");
        assert_eq!(changed.before.as_deref(), Some("2.39-52"));
        assert_eq!(changed.after.as_deref(), Some("2.39-66"));
        assert_eq!(changed.size.as_deref(), Some("+12.0 KiB"));

        let size_only = parse_diff_line("nixos-control: +280.9 KiB").unwrap();
        assert_eq!(size_only.change, "changed");
        assert_eq!(size_only.size.as_deref(), Some("+280.9 KiB"));

        assert!(parse_diff_line("not a diff line").is_none());
    }

    #[test]
    fn compares_two_generation_links() {
        struct DiffRunner {
            args: std::sync::Mutex<Vec<String>>,
        }
        impl CommandRunner for DiffRunner {
            fn run(&self, program: &str, args: &[&str], _timeout: Duration) -> CommandOutput {
                assert_eq!(program, "nix");
                *self.args.lock().unwrap() = args.iter().map(|value| value.to_string()).collect();
                CommandOutput::success(
                    "desktop-xrandr: ∅ → ε\n\
                     nixos-control: \x1b[31;1m+280.9 KiB\x1b[0m\n\
                     foo: 1.0 → 2.0, +12.0 KiB\n\
                     bar: 2.0 → ∅, -3.0 KiB\n",
                )
            }
            fn exists(&self, program: &str) -> bool {
                program == "nix"
            }
        }

        let directory = tempfile::tempdir().expect("tempdir");
        let paths = fixture_paths(directory.path());
        std::fs::create_dir_all(&paths.nix_profiles).unwrap();
        for number in [1, 2] {
            let target = paths.nix_profiles.join(format!("target-{number}"));
            std::fs::write(&target, "").unwrap();
            std::os::unix::fs::symlink(
                &target,
                paths.nix_profiles.join(format!("system-{number}-link")),
            )
            .unwrap();
        }

        let runner = DiffRunner {
            args: std::sync::Mutex::new(Vec::new()),
        };
        let diff = diff_generations(&runner, &paths, 1, 2).unwrap();
        assert_eq!(diff.from, 1);
        assert_eq!(diff.to, 2);
        assert_eq!(diff.added, 1);
        assert_eq!(diff.removed, 1);
        assert_eq!(diff.changed, 2);
        assert_eq!(diff.entries.len(), 4);
        assert!(diff.lines.iter().all(|line| !line.contains('\x1b')));

        let args = runner.args.lock().unwrap().clone();
        assert_eq!(args[0], "--extra-experimental-features");
        assert_eq!(args[1], "nix-command");
        assert_eq!(&args[2..4], &["store", "diff-closures"]);
        assert!(args[4].ends_with("system-1-link"));
        assert!(args[5].ends_with("system-2-link"));
    }

    #[test]
    fn compares_a_generation_with_itself_without_running_nix() {
        let directory = tempfile::tempdir().expect("tempdir");
        let paths = fixture_paths(directory.path());
        let diff = diff_generations(&NoNixEnv, &paths, 3, 3).unwrap();
        assert!(diff.entries.is_empty());
        assert!(diff.lines.is_empty());
    }

    #[test]
    fn missing_generation_is_reported() {
        let directory = tempfile::tempdir().expect("tempdir");
        let paths = fixture_paths(directory.path());
        let error = diff_generations(&NoNixEnv, &paths, 1, 2).unwrap_err();
        assert!(error.contains("generation 1 is not available"));
    }
}
