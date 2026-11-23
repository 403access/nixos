use std::path::PathBuf;
use std::process::Command;

use serde::Serialize;

use crate::util::strip_ansi;

/// Stable path installed by the desktop module. The control server runs as
/// root, so it can invoke the cleanup directly.
pub const DEFAULT_RDP_RESET_SCRIPT: &str = "/etc/nixos-control/rdp-reset";

const OUTPUT_LIMIT: usize = 16 * 1024;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct RdpResetResult {
    pub status: String,
    pub force: bool,
    pub exit_code: Option<i32>,
    pub output: String,
}

/// Abstraction used by the HTTP layer so the RDP reset endpoint can be tested
/// without restarting real desktop services.
pub trait RdpReset: Send + Sync {
    fn reset(&self, force: bool) -> RdpResetResult;
}

#[derive(Debug, Clone)]
pub struct LocalRdp {
    script: PathBuf,
}

impl Default for LocalRdp {
    fn default() -> Self {
        Self::new(DEFAULT_RDP_RESET_SCRIPT)
    }
}

impl LocalRdp {
    pub fn new(script: impl Into<PathBuf>) -> Self {
        Self {
            script: script.into(),
        }
    }
}

impl RdpReset for LocalRdp {
    fn reset(&self, force: bool) -> RdpResetResult {
        let mut command = Command::new(&self.script);
        if force {
            command.arg("--force");
        }

        match command.output() {
            Ok(output) => {
                let mut text = strip_ansi(&String::from_utf8_lossy(&output.stdout));
                let stderr = strip_ansi(&String::from_utf8_lossy(&output.stderr));
                if !stderr.trim().is_empty() {
                    if !text.trim().is_empty() {
                        text.push('\n');
                    }
                    text.push_str(&stderr);
                }
                RdpResetResult {
                    status: if output.status.success() {
                        "ok".to_string()
                    } else {
                        "failed".to_string()
                    },
                    force,
                    exit_code: output.status.code(),
                    output: tail(&text, OUTPUT_LIMIT),
                }
            }
            Err(error) => RdpResetResult {
                status: "failed".to_string(),
                force,
                exit_code: None,
                output: format!("could not run {}: {error}", self.script.display()),
            },
        }
    }
}

fn tail(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_string();
    }
    let mut start = text.len() - limit;
    while start < text.len() && !text.is_char_boundary(start) {
        start += 1;
    }
    format!("…{}", &text[start..])
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn script(directory: &std::path::Path, body: &str) -> PathBuf {
        let path = directory.join("rdp-reset");
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        let mut permissions = std::fs::metadata(&path).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&path, permissions).unwrap();
        path
    }

    #[test]
    fn captures_script_output_and_arguments() {
        let directory = tempfile::tempdir().unwrap();
        let path = script(directory.path(), "echo \"args: $*\"");
        let result = LocalRdp::new(path).reset(true);
        assert_eq!(result.status, "ok");
        assert_eq!(result.exit_code, Some(0));
        assert_eq!(result.output.trim(), "args: --force");
    }

    #[test]
    fn reports_script_failures() {
        let directory = tempfile::tempdir().unwrap();
        let path = script(directory.path(), "echo nope >&2; exit 3");
        let result = LocalRdp::new(path).reset(false);
        assert_eq!(result.status, "failed");
        assert_eq!(result.exit_code, Some(3));
        assert!(result.output.contains("nope"));
    }
}
