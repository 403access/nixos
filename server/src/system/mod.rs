pub mod addresses;
pub mod cpu;
pub mod generations;
pub mod services;
pub mod status;
pub mod storage;
pub mod tailscale;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use crate::commands::{CommandRunner, RealCommandRunner};
use crate::config::AppConfig;
use crate::models::{Generation, ServiceUnit, Status, StorageSnapshot};

/// Filesystem roots used by the system probe. Tests replace these with fixture
/// directories.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SystemPaths {
    pub proc_dir: PathBuf,
    pub sys_dir: PathBuf,
    pub etc_dir: PathBuf,
    pub run_dir: PathBuf,
    pub nix_profiles: PathBuf,
}

impl Default for SystemPaths {
    fn default() -> Self {
        Self {
            proc_dir: PathBuf::from("/proc"),
            sys_dir: PathBuf::from("/sys"),
            etc_dir: PathBuf::from("/etc"),
            run_dir: PathBuf::from("/run"),
            nix_profiles: PathBuf::from("/nix/var/nix/profiles"),
        }
    }
}

/// Everything the HTTP layer needs from the host. Implemented by
/// [`LocalSystem`] in production and by a fixture mock in API tests.
pub trait SystemProbe: Send + Sync {
    fn collect_status(&self) -> Status;
    fn collect_services(&self) -> Vec<ServiceUnit>;
    fn collect_storage(&self) -> StorageSnapshot;
    fn collect_generations(&self) -> Vec<Generation>;
    fn service_action(&self, unit: &str, action: &str) -> Result<(), String>;
    fn service_logs(&self, unit: &str, lines: usize) -> Result<Vec<String>, String>;
    fn system_logs(&self, lines: usize) -> Result<Vec<String>, String>;
    fn pool_status(&self, name: &str) -> Result<String, String>;
    fn power(&self, action: &str) -> Result<(), String>;
}

/// Real host implementation. Commands never involve a shell and every call has
/// a timeout, mirroring the Go server's `runCmd` helper.
pub struct LocalSystem {
    runner: Arc<dyn CommandRunner>,
    paths: SystemPaths,
    version: String,
    allow_rebuild: bool,
    allow_power: bool,
    cpu: Arc<cpu::CpuSampler>,
}

impl LocalSystem {
    pub fn new(config: &AppConfig, version: impl Into<String>) -> Self {
        Self::with_runner(
            Arc::new(RealCommandRunner),
            SystemPaths::default(),
            version,
            config.allow_rebuild,
            config.allow_power,
        )
    }

    pub fn with_runner(
        runner: Arc<dyn CommandRunner>,
        paths: SystemPaths,
        version: impl Into<String>,
        allow_rebuild: bool,
        allow_power: bool,
    ) -> Self {
        let cpu = Arc::new(cpu::CpuSampler::new(paths.proc_dir.join("stat")));
        cpu.prime();
        Self {
            runner,
            paths,
            version: version.into(),
            allow_rebuild,
            allow_power,
            cpu,
        }
    }
}

impl SystemProbe for LocalSystem {
    fn collect_status(&self) -> Status {
        status::collect_status(
            self.runner.as_ref(),
            &self.paths,
            &self.version,
            self.allow_rebuild,
            self.allow_power,
            &self.cpu,
        )
    }

    fn collect_services(&self) -> Vec<ServiceUnit> {
        services::collect_service_units(self.runner.as_ref())
    }

    fn collect_storage(&self) -> StorageSnapshot {
        storage::collect_storage(self.runner.as_ref())
    }

    fn collect_generations(&self) -> Vec<Generation> {
        generations::collect_generations(self.runner.as_ref(), &self.paths)
    }

    fn service_action(&self, unit: &str, action: &str) -> Result<(), String> {
        let result = self
            .runner
            .run("systemctl", &[action, unit], Duration::from_secs(30));
        command_result(result)
    }

    fn service_logs(&self, unit: &str, lines: usize) -> Result<Vec<String>, String> {
        let lines = lines.to_string();
        let result = self.runner.run(
            "journalctl",
            &["-u", unit, "-n", &lines, "--no-pager", "-o", "short-iso"],
            Duration::from_secs(20),
        );
        command_lines(result)
    }

    fn system_logs(&self, lines: usize) -> Result<Vec<String>, String> {
        let lines = lines.to_string();
        let result = self.runner.run(
            "journalctl",
            &["-n", &lines, "--no-pager", "-o", "short-iso"],
            Duration::from_secs(20),
        );
        command_lines(result)
    }

    fn pool_status(&self, name: &str) -> Result<String, String> {
        let result = self
            .runner
            .run("zpool", &["status", name], Duration::from_secs(15));
        match result.error {
            None => Ok(result.output),
            Some(error) => {
                let message = result.output.trim();
                Err(if message.is_empty() {
                    error
                } else {
                    message.to_string()
                })
            }
        }
    }

    fn power(&self, action: &str) -> Result<(), String> {
        let result = self.runner.run(
            "systemctl",
            &["--no-block", action],
            Duration::from_secs(10),
        );
        command_result(result)
    }
}

fn command_result(result: crate::commands::CommandOutput) -> Result<(), String> {
    match result.error {
        None => Ok(()),
        Some(error) => {
            let message = result.output.trim();
            Err(if message.is_empty() {
                error
            } else {
                message.to_string()
            })
        }
    }
}

fn command_lines(result: crate::commands::CommandOutput) -> Result<Vec<String>, String> {
    match result.error {
        Some(error) if result.output.trim().is_empty() => Err(error),
        _ => Ok(crate::util::split_lines(&result.output)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::CommandOutput;
    use std::sync::Mutex;

    struct RecordingRunner {
        calls: Mutex<Vec<(String, Vec<String>)>>,
        exists: bool,
    }

    impl RecordingRunner {
        fn new(exists: bool) -> Arc<Self> {
            Arc::new(Self {
                calls: Mutex::new(Vec::new()),
                exists,
            })
        }

        fn calls(&self) -> Vec<(String, Vec<String>)> {
            self.calls.lock().unwrap().clone()
        }
    }

    impl CommandRunner for RecordingRunner {
        fn run(&self, program: &str, args: &[&str], _timeout: Duration) -> CommandOutput {
            self.calls.lock().unwrap().push((
                program.to_string(),
                args.iter().map(|value| value.to_string()).collect(),
            ));
            CommandOutput::success("output")
        }

        fn exists(&self, _program: &str) -> bool {
            self.exists
        }
    }

    fn system_with(runner: Arc<RecordingRunner>, directory: &std::path::Path) -> LocalSystem {
        LocalSystem::with_runner(
            runner,
            SystemPaths {
                proc_dir: directory.join("proc"),
                sys_dir: directory.join("sys"),
                etc_dir: directory.join("etc"),
                run_dir: directory.join("run"),
                nix_profiles: directory.join("nix/var/nix/profiles"),
            },
            "test-version",
            true,
            false,
        )
    }

    #[test]
    fn forwards_system_commands_with_expected_arguments() {
        let directory = tempfile::tempdir().unwrap();
        let runner = RecordingRunner::new(true);
        let system = system_with(runner.clone(), directory.path());

        system.service_action("nginx.service", "restart").unwrap();
        system.service_logs("nginx.service", 50).unwrap();
        system.system_logs(300).unwrap();
        system.pool_status("tank").unwrap();
        system.power("poweroff").unwrap();

        assert_eq!(
            runner.calls(),
            vec![
                (
                    "systemctl".to_string(),
                    vec!["restart".to_string(), "nginx.service".to_string()]
                ),
                (
                    "journalctl".to_string(),
                    vec![
                        "-u".to_string(),
                        "nginx.service".to_string(),
                        "-n".to_string(),
                        "50".to_string(),
                        "--no-pager".to_string(),
                        "-o".to_string(),
                        "short-iso".to_string()
                    ]
                ),
                (
                    "journalctl".to_string(),
                    vec![
                        "-n".to_string(),
                        "300".to_string(),
                        "--no-pager".to_string(),
                        "-o".to_string(),
                        "short-iso".to_string()
                    ]
                ),
                (
                    "zpool".to_string(),
                    vec!["status".to_string(), "tank".to_string()]
                ),
                (
                    "systemctl".to_string(),
                    vec!["--no-block".to_string(), "poweroff".to_string()]
                )
            ]
        );
    }

    #[test]
    fn command_errors_use_trimmed_output_when_present() {
        struct FailingRunner;
        impl CommandRunner for FailingRunner {
            fn run(&self, _program: &str, _args: &[&str], _timeout: Duration) -> CommandOutput {
                CommandOutput::failure("  nope  \n", "exit status 1")
            }
            fn exists(&self, _program: &str) -> bool {
                true
            }
        }

        let directory = tempfile::tempdir().unwrap();
        let system = LocalSystem::with_runner(
            Arc::new(FailingRunner),
            SystemPaths {
                proc_dir: directory.path().join("proc"),
                sys_dir: directory.path().join("sys"),
                etc_dir: directory.path().join("etc"),
                run_dir: directory.path().join("run"),
                nix_profiles: directory.path().join("nix/var/nix/profiles"),
            },
            "test",
            true,
            true,
        );

        assert_eq!(
            system.service_action("nginx.service", "start"),
            Err("nope".to_string())
        );
        assert_eq!(system.pool_status("tank"), Err("nope".to_string()));
    }

    #[test]
    fn collects_a_complete_status_from_fixture_paths() {
        struct StatusRunner;
        impl CommandRunner for StatusRunner {
            fn run(&self, program: &str, args: &[&str], _timeout: Duration) -> CommandOutput {
                match program {
                    "df" if args.contains(&"-T") => CommandOutput::success(
                        "Filesystem Type 1-blocks Used Available Capacity Mounted on\n/dev/sda1 ext4 1000 400 600 40% /\n",
                    ),
                    "df" => CommandOutput::success(
                        "Filesystem 1-blocks Used Available Capacity Mounted on\n/dev/sda1 1000 400 600 40% /\n",
                    ),
                    "zpool" => CommandOutput::success(
                        "tank\t1000\t400\t600\tONLINE\t5\n",
                    ),
                    "systemctl" => CommandOutput::success(
                        "nginx.service loaded active running web\ndb.service loaded failed failed database\n",
                    ),
                    _ => CommandOutput::failure("", "unexpected command"),
                }
            }
            fn exists(&self, program: &str) -> bool {
                program != "tailscale"
            }
        }

        let directory = tempfile::tempdir().unwrap();
        let root = directory.path();
        let sys = SystemPaths {
            proc_dir: root.join("proc"),
            sys_dir: root.join("sys"),
            etc_dir: root.join("etc"),
            run_dir: root.join("run"),
            nix_profiles: root.join("nix/var/nix/profiles"),
        };
        std::fs::create_dir_all(sys.proc_dir.join("sys/kernel")).unwrap();
        std::fs::create_dir_all(sys.etc_dir.join("")).unwrap();
        std::fs::create_dir_all(sys.run_dir.join("current-system")).unwrap();
        std::fs::create_dir_all(sys.sys_dir.join("class/hwmon/hwmon0")).unwrap();
        std::fs::create_dir_all(&sys.nix_profiles).unwrap();

        std::fs::write(sys.proc_dir.join("uptime"), "1234.5 1000.0\n").unwrap();
        std::fs::write(sys.proc_dir.join("loadavg"), "0.50 0.25 0.10 1/100 42\n").unwrap();
        std::fs::write(sys.proc_dir.join("sys/kernel/osrelease"), "6.6.0-test\n").unwrap();
        std::fs::write(
            sys.proc_dir.join("cpuinfo"),
            "processor\t: 0\nmodel name\t: Test CPU\n",
        )
        .unwrap();
        std::fs::write(
            sys.proc_dir.join("meminfo"),
            "MemTotal: 1000 kB\nMemFree: 100 kB\nMemAvailable: 400 kB\nSwapTotal: 200 kB\nSwapFree: 150 kB\n",
        )
        .unwrap();
        std::fs::write(sys.proc_dir.join("stat"), "cpu  10 0 10 80 0 0 0 0\n").unwrap();
        std::fs::write(
            sys.etc_dir.join("os-release"),
            "PRETTY_NAME=\"NixOS 25.11 (Xantusia)\"\nVERSION=\"25.11.20250101\"\n",
        )
        .unwrap();
        std::fs::write(
            sys.run_dir.join("current-system/nixos-version"),
            "25.11.20250101\n",
        )
        .unwrap();
        std::fs::write(
            sys.sys_dir.join("class/hwmon/hwmon0/temp1_input"),
            "42000\n",
        )
        .unwrap();
        std::fs::write(sys.sys_dir.join("class/hwmon/hwmon0/temp1_label"), "CPU\n").unwrap();

        let target = sys.nix_profiles.join("target-7");
        std::fs::write(&target, "").unwrap();
        std::os::unix::fs::symlink(&target, sys.nix_profiles.join("system-7-link")).unwrap();
        std::os::unix::fs::symlink("system-7-link", sys.nix_profiles.join("system")).unwrap();

        let system =
            LocalSystem::with_runner(Arc::new(StatusRunner), sys, "test-version", true, false);
        let status = system.collect_status();

        assert_eq!(status.server_version, "test-version");
        assert!(!status.hostname.is_empty());
        assert_eq!(status.os, "NixOS 25.11 (Xantusia)");
        assert_eq!(status.kernel, "6.6.0-test");
        assert_eq!(status.nixos_version, "25.11.20250101");
        assert_eq!(status.uptime_seconds, 1234);
        assert_eq!(status.load, vec![0.5, 0.25, 0.1]);
        assert_eq!(status.cpu.model, "Test CPU");
        assert!(status.cpu.cores >= 1);
        assert_eq!(status.memory.total, 1000 * 1024);
        assert_eq!(status.memory.used, 600 * 1024);
        assert_eq!(status.memory.swap_used, 50 * 1024);
        assert_eq!(status.root_disk.mount, "/");
        assert_eq!(status.root_disk.total, 1000);
        assert_eq!(status.pools.len(), 1);
        assert_eq!(status.pools[0].health, "ONLINE");
        assert_eq!(status.temperatures.len(), 1);
        assert_eq!(status.temperatures[0].label, "CPU");
        assert_eq!(status.temperatures[0].celsius, 42.0);
        assert_eq!(status.generation, 7);
        assert_eq!(status.tailscale.as_ref().unwrap().state, "not installed");
        assert_eq!(status.services.total, 2);
        assert_eq!(status.services.running, 1);
        assert_eq!(status.services.failed, 1);
        assert!(status.capabilities.services);
        assert!(status.capabilities.rebuild);
        assert!(!status.capabilities.power);
    }
}
