use std::io::Read;
use std::path::Path;
use std::process::{Command, ExitStatus, Stdio};
use std::thread;
use std::time::Duration;

use wait_timeout::ChildExt;

/// Combined stdout/stderr plus an optional execution error, matching the
/// behaviour of Go's `exec.CombinedOutput`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandOutput {
    pub output: String,
    pub error: Option<String>,
}

impl CommandOutput {
    pub fn success(output: impl Into<String>) -> Self {
        Self {
            output: output.into(),
            error: None,
        }
    }

    pub fn failure(output: impl Into<String>, error: impl Into<String>) -> Self {
        Self {
            output: output.into(),
            error: Some(error.into()),
        }
    }

    pub fn is_ok(&self) -> bool {
        self.error.is_none()
    }
}

/// Runs external commands without a shell. Injected into the system probe so
/// the API can be tested without touching the host.
pub trait CommandRunner: Send + Sync {
    fn run(&self, program: &str, args: &[&str], timeout: Duration) -> CommandOutput;
    fn exists(&self, program: &str) -> bool;
}

#[derive(Debug, Default, Clone, Copy)]
pub struct RealCommandRunner;

impl CommandRunner for RealCommandRunner {
    fn run(&self, program: &str, args: &[&str], timeout: Duration) -> CommandOutput {
        let mut command = Command::new(program);
        command
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => return CommandOutput::failure("", error.to_string()),
        };

        let stdout = child.stdout.take();
        let stderr = child.stderr.take();

        let stdout_reader = stdout.map(|mut stream| {
            thread::spawn(move || {
                let mut buffer = Vec::new();
                let _ = stream.read_to_end(&mut buffer);
                buffer
            })
        });
        let stderr_reader = stderr.map(|mut stream| {
            thread::spawn(move || {
                let mut buffer = Vec::new();
                let _ = stream.read_to_end(&mut buffer);
                buffer
            })
        });

        let mut timed_out = false;
        let mut wait_error = None;
        let status: Option<ExitStatus> = match child.wait_timeout(timeout) {
            Ok(Some(status)) => Some(status),
            Ok(None) => {
                timed_out = true;
                let _ = child.kill();
                let _ = child.wait();
                None
            }
            Err(error) => {
                wait_error = Some(error.to_string());
                let _ = child.kill();
                let _ = child.wait();
                None
            }
        };

        let stdout = stdout_reader
            .and_then(|handle| handle.join().ok())
            .unwrap_or_default();
        let stderr = stderr_reader
            .and_then(|handle| handle.join().ok())
            .unwrap_or_default();

        let mut output = String::from_utf8_lossy(&stdout).into_owned();
        output.push_str(&String::from_utf8_lossy(&stderr));

        if timed_out {
            return CommandOutput::failure(
                output,
                format!("{program} timed out after {timeout:?}"),
            );
        }
        if let Some(error) = wait_error {
            return CommandOutput::failure(output, error);
        }

        match status {
            Some(status) if status.success() => CommandOutput::success(output),
            Some(status) => CommandOutput::failure(output, describe_exit_status(status)),
            None => CommandOutput::failure(output, "command did not exit"),
        }
    }

    fn exists(&self, program: &str) -> bool {
        if program.contains('/') {
            return is_executable(Path::new(program));
        }
        let Some(path) = std::env::var_os("PATH") else {
            return false;
        };
        std::env::split_paths(&path).any(|directory| is_executable(&directory.join(program)))
    }
}

fn describe_exit_status(status: ExitStatus) -> String {
    match status.code() {
        Some(code) => format!("exit status {code}"),
        None => "signal: terminated".to_string(),
    }
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata()
            .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runs_a_command_and_combines_streams() {
        let runner = RealCommandRunner;
        let result = runner.run(
            "sh",
            &["-c", "printf out; printf err >&2"],
            Duration::from_secs(5),
        );
        assert!(result.is_ok(), "unexpected error: {:?}", result.error);
        assert!(result.output.contains("out"));
        assert!(result.output.contains("err"));
    }

    #[test]
    fn reports_exit_status_and_output() {
        let runner = RealCommandRunner;
        let result = runner.run(
            "sh",
            &["-c", "printf bad >&2; exit 3"],
            Duration::from_secs(5),
        );
        assert_eq!(result.error.as_deref(), Some("exit status 3"));
        assert_eq!(result.output, "bad");
    }

    #[test]
    fn reports_spawn_failures() {
        let runner = RealCommandRunner;
        let result = runner.run(
            "definitely-not-a-real-command-xyz",
            &[],
            Duration::from_secs(1),
        );
        assert!(result.error.is_some());
        assert!(result.output.is_empty());
    }

    #[test]
    fn kills_commands_after_the_timeout() {
        let runner = RealCommandRunner;
        let result = runner.run("sh", &["-c", "exec sleep 5"], Duration::from_millis(100));
        assert!(result
            .error
            .as_deref()
            .unwrap_or_default()
            .contains("timed out"));
    }

    #[test]
    fn finds_programs_on_path() {
        let runner = RealCommandRunner;
        assert!(runner.exists("sh"));
        assert!(!runner.exists("definitely-not-a-real-command-xyz"));
    }
}
