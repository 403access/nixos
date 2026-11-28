//! Agent sandbox inventory and lifecycle for the web and iOS apps.
//!
//! The authoritative state lives in the `agent-vm` state directory written by
//! the sandbox CLI.  This module reads that state, exposes it as JSON, and
//! shells out to `agent-vm` for start/stop/remove/create.  The API token is
//! already root-equivalent, but create requests are still restricted to the
//! sandbox workspace and share roots from the module.

use std::fs;
use std::net::Ipv4Addr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::commands::{CommandRunner, RealCommandRunner};
use crate::config::AppConfig;
use crate::models::LogsResponse;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct SandboxPort {
    pub address: String,
    pub host: u16,
    pub guest: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct SandboxShare {
    pub name: String,
    pub path: String,
    pub read_only: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct Sandbox {
    pub name: String,
    pub status: String,
    pub running: bool,
    pub image: String,
    pub cpus: u32,
    pub memory: u32,
    pub dns: String,
    pub online: bool,
    pub lan: bool,
    pub ephemeral: bool,
    pub docker: bool,
    pub workspace: String,
    pub created: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    pub ports: Vec<SandboxPort>,
    pub shares: Vec<SandboxShare>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct SandboxList {
    pub available: bool,
    pub workspace_root: String,
    pub shared_root: String,
    pub sandboxes: Vec<Sandbox>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct SandboxPortRequest {
    #[serde(default)]
    pub address: Option<String>,
    pub host: u16,
    pub guest: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct SandboxShareRequest {
    pub name: String,
    pub path: String,
    #[serde(default)]
    pub read_only: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct SandboxCreateRequest {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub image: String,
    /// A single directory name below the workspace root.  Empty uses `name`.
    #[serde(default)]
    pub workspace: String,
    #[serde(default)]
    pub cpus: u32,
    #[serde(default)]
    pub memory: u32,
    #[serde(default)]
    pub online: bool,
    #[serde(default)]
    pub lan: bool,
    #[serde(default)]
    pub docker: bool,
    #[serde(default)]
    pub ephemeral: bool,
    #[serde(default)]
    pub ports: Vec<SandboxPortRequest>,
    #[serde(default)]
    pub shares: Vec<SandboxShareRequest>,
    /// Guest command.  Empty runs the image entrypoint.
    #[serde(default)]
    pub command: Vec<String>,
}

/// Abstraction used by the HTTP layer so sandbox endpoints can be tested
/// without touching the host.
pub trait SandboxProbe: Send + Sync {
    fn list(&self) -> SandboxList;
    fn logs(&self, name: &str, lines: usize) -> Result<LogsResponse, String>;
    fn start(&self, name: &str) -> Result<(), String>;
    fn stop(&self, name: &str) -> Result<(), String>;
    fn remove(&self, name: &str) -> Result<(), String>;
    /// Validate a create request and return the `agent-vm` arguments.
    fn create_args(&self, request: &SandboxCreateRequest) -> Result<Vec<String>, String>;
}

pub struct LocalSandboxes {
    runner: Arc<dyn CommandRunner>,
    state_root: PathBuf,
    run_root: PathBuf,
    workspaces: PathBuf,
    shares: PathBuf,
    agent_vm: String,
}

impl LocalSandboxes {
    pub fn new(config: &AppConfig) -> Self {
        Self::with_runner(
            Arc::new(RealCommandRunner),
            &config.sandbox_state,
            &config.sandbox_run,
            &config.sandbox_workspaces,
            &config.sandbox_shares,
            &config.agent_vm,
        )
    }

    pub fn with_runner(
        runner: Arc<dyn CommandRunner>,
        state_root: impl Into<PathBuf>,
        run_root: impl Into<PathBuf>,
        workspaces: impl Into<PathBuf>,
        shares: impl Into<PathBuf>,
        agent_vm: impl Into<String>,
    ) -> Self {
        Self {
            runner,
            state_root: state_root.into(),
            run_root: run_root.into(),
            workspaces: workspaces.into(),
            shares: shares.into(),
            agent_vm: agent_vm.into(),
        }
    }

    fn state_dir(&self) -> PathBuf {
        self.state_root.join("state")
    }

    fn action(&self, name: &str, args: &[&str]) -> Result<(), String> {
        if !valid_name(name) {
            return Err("invalid sandbox name".to_string());
        }
        let output = self
            .runner
            .run(&self.agent_vm, args, Duration::from_secs(90));
        if let Some(error) = output.error {
            let message = output.output.trim();
            return Err(if message.is_empty() {
                error
            } else {
                message.to_string()
            });
        }
        Ok(())
    }

    fn read_state(&self, name: &str) -> Option<Sandbox> {
        let path = self.state_dir().join(format!("{name}.conf"));
        let content = fs::read_to_string(path).ok()?;
        let mut sandbox = parse_state(&content);
        if sandbox.name.is_empty() {
            sandbox.name = name.to_string();
        }
        sandbox.ports = self.read_ports(name);
        sandbox.shares = self.read_shares(name);
        sandbox.pid = fs::read_to_string(self.state_dir().join(format!("{name}.pid")))
            .ok()
            .and_then(|value| value.trim().parse::<u32>().ok());
        Some(sandbox)
    }

    fn read_ports(&self, name: &str) -> Vec<SandboxPort> {
        let path = self.state_dir().join(format!("{name}.ports"));
        let Ok(content) = fs::read_to_string(path) else {
            return Vec::new();
        };
        content
            .lines()
            .filter_map(|line| {
                let fields: Vec<&str> = line.split('\t').collect();
                if fields.len() < 3 {
                    return None;
                }
                Some(SandboxPort {
                    address: fields[0].to_string(),
                    host: fields[1].parse().ok()?,
                    guest: fields[2].parse().ok()?,
                })
            })
            .collect()
    }

    fn read_shares(&self, name: &str) -> Vec<SandboxShare> {
        let path = self.state_dir().join(format!("{name}.shares"));
        let Ok(content) = fs::read_to_string(path) else {
            return Vec::new();
        };
        content
            .lines()
            .filter_map(|line| {
                let fields: Vec<&str> = line.split('\t').collect();
                if fields.len() < 3 {
                    return None;
                }
                Some(SandboxShare {
                    name: fields[0].to_string(),
                    path: fields[1].to_string(),
                    read_only: fields[2] == "1",
                })
            })
            .collect()
    }
}

impl SandboxProbe for LocalSandboxes {
    fn list(&self) -> SandboxList {
        let state_dir = self.state_dir();
        let available = self.runner.exists(&self.agent_vm) || state_dir.exists();
        let mut sandboxes = Vec::new();
        if let Ok(entries) = fs::read_dir(&state_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|value| value.to_str()) != Some("conf") {
                    continue;
                }
                let Some(name) = path.file_stem().and_then(|value| value.to_str()) else {
                    continue;
                };
                if let Some(sandbox) = self.read_state(name) {
                    sandboxes.push(sandbox);
                }
            }
        }
        sandboxes.sort_by(|left, right| left.name.cmp(&right.name));
        SandboxList {
            available,
            workspace_root: self.workspaces.to_string_lossy().to_string(),
            shared_root: self.shares.to_string_lossy().to_string(),
            sandboxes,
        }
    }

    fn logs(&self, name: &str, lines: usize) -> Result<LogsResponse, String> {
        if !valid_name(name) {
            return Err("invalid sandbox name".to_string());
        }
        let path = self.run_root.join("log").join(format!("{name}.log"));
        let content = fs::read_to_string(path).unwrap_or_default();
        let mut entries: Vec<&str> = content.lines().collect();
        let start = entries.len().saturating_sub(lines);
        entries.drain(..start);
        Ok(LogsResponse {
            lines: entries.into_iter().map(str::to_string).collect(),
            entries: Vec::new(),
        })
    }

    fn start(&self, name: &str) -> Result<(), String> {
        self.action(name, &["start", "--detach", name])
    }

    fn stop(&self, name: &str) -> Result<(), String> {
        self.action(name, &["stop", name])
    }

    fn remove(&self, name: &str) -> Result<(), String> {
        self.action(name, &["rm", name])
    }

    fn create_args(&self, request: &SandboxCreateRequest) -> Result<Vec<String>, String> {
        if !valid_name(&request.name) {
            return Err(
                "name must start with a letter or digit and contain only letters, digits, '.', '_' or '-'"
                    .to_string(),
            );
        }
        if request.ports.len() > 16 {
            return Err("at most 16 published ports are allowed".to_string());
        }
        if request.shares.len() > 16 {
            return Err("at most 16 shared folders are allowed".to_string());
        }
        if request.command.len() > 128 {
            return Err("command is too long".to_string());
        }
        for arg in &request.command {
            if arg.contains('\n') || arg.contains('\t') {
                return Err("command arguments cannot contain newlines or tabs".to_string());
            }
        }

        let workspace_name = if request.workspace.trim().is_empty() {
            request.name.trim()
        } else {
            request.workspace.trim()
        };
        if !valid_component(workspace_name) {
            return Err("workspace must be a single directory name".to_string());
        }
        let workspace = self.workspaces.join(workspace_name);
        fs::create_dir_all(&workspace)
            .map_err(|error| format!("could not create workspace: {error}"))?;
        set_owner_from(&self.workspaces, &workspace);
        if !workspace.is_dir() {
            return Err("workspace is not a directory".to_string());
        }

        if request.cpus != 0 && !(1..=8).contains(&request.cpus) {
            return Err("cpus must be between 1 and 8".to_string());
        }
        if request.memory != 0 && !(256..=16384).contains(&request.memory) {
            return Err("memory must be between 256 and 16384 MiB".to_string());
        }

        let mut args = vec![
            "run".to_string(),
            "--detach".to_string(),
            "--name".to_string(),
            request.name.clone(),
            "--workspace".to_string(),
            workspace.to_string_lossy().to_string(),
        ];
        if !request.image.trim().is_empty() {
            if !valid_image(request.image.trim()) {
                return Err("invalid image reference".to_string());
            }
            args.push("--image".to_string());
            args.push(request.image.trim().to_string());
        }
        if request.cpus != 0 {
            args.push("--cpus".to_string());
            args.push(request.cpus.to_string());
        }
        if request.memory != 0 {
            args.push("--mem".to_string());
            args.push(request.memory.to_string());
        }
        if request.online || request.lan {
            args.push("--online".to_string());
        }
        if request.lan {
            args.push("--lan".to_string());
        }
        if request.docker {
            args.push("--docker".to_string());
        }
        if request.ephemeral {
            args.push("--ephemeral".to_string());
        }

        let mut seen_host_ports = Vec::new();
        for port in &request.ports {
            if port.host < 1024 {
                return Err("host ports must be 1024 or higher".to_string());
            }
            if port.guest == 0 {
                return Err("guest ports must be between 1 and 65535".to_string());
            }
            if seen_host_ports.contains(&port.host) {
                return Err(format!("host port {} is listed twice", port.host));
            }
            seen_host_ports.push(port.host);
            let address = port.address.as_deref().unwrap_or("127.0.0.1");
            if address == "127.0.0.1" {
                args.push("--port".to_string());
                args.push(format!("{}:{}", port.host, port.guest));
            } else {
                if address != "0.0.0.0" && address.parse::<Ipv4Addr>().is_err() {
                    return Err(format!("invalid publish address: {address}"));
                }
                args.push("--publish".to_string());
                args.push(format!("{address}:{}:{}", port.host, port.guest));
            }
        }

        let mut seen_share_names = Vec::new();
        let shares_root = if request.shares.is_empty() {
            None
        } else {
            Some(
                fs::canonicalize(&self.shares)
                    .map_err(|error| format!("shared folder root is not available: {error}"))?,
            )
        };
        for share in &request.shares {
            if !valid_component(&share.name) {
                return Err("share names must be single directory names".to_string());
            }
            if seen_share_names.contains(&share.name) {
                return Err(format!("share {} is listed twice", share.name));
            }
            seen_share_names.push(share.name.clone());
            let path = fs::canonicalize(&share.path).map_err(|error| {
                format!("shared folder {} is not available: {error}", share.path)
            })?;
            if let Some(root) = &shares_root {
                if !path.starts_with(root) || &path == root {
                    return Err(format!(
                        "shared folder {} must be below {}",
                        share.path,
                        self.shares.display()
                    ));
                }
            }
            if !path.is_dir() {
                return Err(format!("shared folder {} is not a directory", share.path));
            }
            let mut value = format!("{}={}", share.name, path.to_string_lossy());
            if share.read_only {
                value.push_str(":ro");
            }
            args.push("--share".to_string());
            args.push(value);
        }

        if !request.command.is_empty() {
            args.push("--".to_string());
            args.extend(request.command.iter().cloned());
        }
        Ok(args)
    }
}

fn parse_state(content: &str) -> Sandbox {
    let mut sandbox = Sandbox::default();
    for line in content.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = unquote_shell(value);
        match key {
            "name" => sandbox.name = value,
            "status" => sandbox.status = value,
            "image" => sandbox.image = value,
            "cpus" => sandbox.cpus = value.parse().unwrap_or(0),
            "mem" => sandbox.memory = value.parse().unwrap_or(0),
            "dns" => sandbox.dns = value,
            "online" => sandbox.online = value == "1",
            "lan" => sandbox.lan = value == "1",
            "ephemeral" => sandbox.ephemeral = value == "1",
            "docker" => sandbox.docker = value == "1",
            "workspace" => sandbox.workspace = value,
            "created" => sandbox.created = value,
            _ => {}
        }
    }
    if sandbox.status.is_empty() {
        sandbox.status = "stopped".to_string();
    }
    sandbox.running = sandbox.status == "running";
    sandbox
}

/// Undo the `key=%q` quoting used by `agent-vm` state files.
fn unquote_shell(raw: &str) -> String {
    let value = raw.trim();
    if value.len() >= 2 && value.starts_with('\'') && value.ends_with('\'') {
        return value[1..value.len() - 1].replace("'\\''", "'");
    }
    if value.len() >= 3 && value.starts_with("$'") && value.ends_with('\'') {
        return unescape(&value[2..value.len() - 1]);
    }
    unescape(value)
}

fn unescape(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(character) = chars.next() {
        if character == '\\' {
            if let Some(next) = chars.next() {
                result.push(next);
            }
        } else {
            result.push(character);
        }
    }
    result
}

fn valid_name(value: &str) -> bool {
    valid_component(value) && value.len() <= 63
}

fn valid_component(value: &str) -> bool {
    if value.is_empty() || value == "." || value == ".." || value.len() > 63 {
        return false;
    }
    let mut chars = value.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !first.is_ascii_alphanumeric() {
        return false;
    }
    chars.all(|character| character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-'))
}

fn valid_image(value: &str) -> bool {
    !value.starts_with('-')
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric()
                || matches!(character, '.' | ':' | '/' | '@' | '+' | '-' | '_')
        })
}

#[cfg(unix)]
fn set_owner_from(parent: &Path, path: &Path) {
    use std::os::unix::fs::MetadataExt;
    if let Ok(metadata) = fs::metadata(parent) {
        let _ = std::os::unix::fs::chown(path, Some(metadata.uid()), Some(metadata.gid()));
    }
}

#[cfg(not(unix))]
fn set_owner_from(_parent: &Path, _path: &Path) {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::CommandOutput;
    use std::sync::Mutex;

    #[derive(Default)]
    struct FakeRunner {
        calls: Mutex<Vec<String>>,
        exists: bool,
    }

    impl CommandRunner for FakeRunner {
        fn run(&self, program: &str, args: &[&str], _timeout: Duration) -> CommandOutput {
            self.calls
                .lock()
                .unwrap()
                .push(format!("{program} {}", args.join(" ")));
            CommandOutput::success("ok")
        }

        fn exists(&self, _program: &str) -> bool {
            self.exists
        }
    }

    fn local_with_calls(temp: &tempfile::TempDir) -> (LocalSandboxes, Arc<FakeRunner>) {
        let runner = Arc::new(FakeRunner {
            exists: true,
            ..FakeRunner::default()
        });
        let sandboxes = LocalSandboxes::with_runner(
            runner.clone(),
            temp.path().join("state-root"),
            temp.path().join("run"),
            temp.path().join("workspaces"),
            temp.path().join("shares"),
            "agent-vm",
        );
        (sandboxes, runner)
    }

    fn local(temp: &tempfile::TempDir) -> LocalSandboxes {
        local_with_calls(temp).0
    }

    #[test]
    fn parses_state_and_port_files() {
        let temp = tempfile::tempdir().unwrap();
        let sandboxes = local(&temp);
        let state = temp.path().join("state-root/state");
        fs::create_dir_all(&state).unwrap();
        fs::write(
            state.join("demo.conf"),
            "name=demo\nidx=1\nimage=docker.io/library/alpine:latest\ncpus=2\nmem=512\ndns=1.1.1.1\nonline=1\nlan=0\nstatus=running\nephemeral=0\ndocker=1\nworkspace='/var/lib/agent-workspaces/demo'\ncreated=2026-01-01T00:00:00Z\n",
        )
        .unwrap();
        fs::write(state.join("demo.ports"), "127.0.0.1\t8080\t80\t20000\n").unwrap();
        fs::write(
            state.join("demo.shares"),
            "team\t/srv/team\t1\t/share-team\n",
        )
        .unwrap();
        fs::write(state.join("demo.pid"), "123\n").unwrap();

        let listed = sandboxes.list();
        assert!(listed.available);
        assert_eq!(listed.sandboxes.len(), 1);
        let sandbox = &listed.sandboxes[0];
        assert_eq!(sandbox.name, "demo");
        assert!(sandbox.running);
        assert!(sandbox.online);
        assert!(sandbox.docker);
        assert_eq!(sandbox.cpus, 2);
        assert_eq!(sandbox.workspace, "/var/lib/agent-workspaces/demo");
        assert_eq!(sandbox.pid, Some(123));
        assert_eq!(sandbox.ports[0].host, 8080);
        assert!(sandbox.shares[0].read_only);
    }

    #[test]
    fn builds_create_arguments_for_workspace_and_ports() {
        let temp = tempfile::tempdir().unwrap();
        let sandboxes = local(&temp);
        fs::create_dir_all(temp.path().join("shares/team")).unwrap();
        let request = SandboxCreateRequest {
            name: "demo".to_string(),
            image: "docker.io/library/alpine:latest".to_string(),
            workspace: "project".to_string(),
            cpus: 2,
            memory: 512,
            online: true,
            docker: true,
            ports: vec![
                SandboxPortRequest {
                    address: None,
                    host: 8080,
                    guest: 80,
                },
                SandboxPortRequest {
                    address: Some("0.0.0.0".to_string()),
                    host: 8081,
                    guest: 81,
                },
            ],
            shares: vec![SandboxShareRequest {
                name: "team".to_string(),
                path: temp
                    .path()
                    .join("shares/team")
                    .to_string_lossy()
                    .to_string(),
                read_only: true,
            }],
            command: vec![
                "/bin/sh".to_string(),
                "-c".to_string(),
                "echo hi".to_string(),
            ],
            ..SandboxCreateRequest::default()
        };
        let args = sandboxes.create_args(&request).unwrap();
        assert_eq!(args[0], "run");
        assert!(args.contains(&"--detach".to_string()));
        assert!(args
            .iter()
            .any(|value| value.ends_with("/workspaces/project")));
        assert!(args.contains(&"--online".to_string()));
        assert!(args.contains(&"--docker".to_string()));
        assert!(args.contains(&"8080:80".to_string()));
        assert!(args.contains(&"0.0.0.0:8081:81".to_string()));
        assert!(args.iter().any(|value| value.ends_with("/shares/team:ro")));
        assert!(args.contains(&"echo hi".to_string()));
    }

    #[test]
    fn actions_use_the_agent_vm_cli() {
        let temp = tempfile::tempdir().unwrap();
        let (sandboxes, runner) = local_with_calls(&temp);
        sandboxes.start("demo").unwrap();
        sandboxes.stop("demo").unwrap();
        sandboxes.remove("demo").unwrap();
        assert_eq!(
            runner.calls.lock().unwrap().clone(),
            vec![
                "agent-vm start --detach demo",
                "agent-vm stop demo",
                "agent-vm rm demo"
            ]
        );
    }

    #[test]
    fn rejects_invalid_names_and_paths() {
        let temp = tempfile::tempdir().unwrap();
        let sandboxes = local(&temp);
        assert!(sandboxes.start("../escape").is_err());
        let request = SandboxCreateRequest {
            name: "demo".to_string(),
            workspace: "../escape".to_string(),
            ..SandboxCreateRequest::default()
        };
        assert!(sandboxes.create_args(&request).is_err());
    }
}
