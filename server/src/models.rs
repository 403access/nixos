use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CpuInfo {
    pub model: String,
    pub cores: usize,
    pub usage_percent: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct MemoryInfo {
    pub total: i64,
    pub used: i64,
    pub free: i64,
    pub available: i64,
    pub cached: i64,
    pub swap_total: i64,
    pub swap_used: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct DiskUsage {
    pub mount: String,
    pub total: i64,
    pub used: i64,
    pub available: i64,
    pub use_percent: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct PoolInfo {
    pub name: String,
    pub size: i64,
    pub allocated: i64,
    pub free: i64,
    pub health: String,
    pub fragmentation: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Temperature {
    pub label: String,
    pub celsius: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct TailscaleInfo {
    pub connected: bool,
    pub hostname: String,
    pub dns_name: String,
    pub ips: Vec<String>,
    pub state: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct ServiceCounts {
    pub running: usize,
    pub failed: usize,
    pub total: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Capabilities {
    pub services: bool,
    pub rebuild: bool,
    pub power: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Status {
    pub server_version: String,
    pub hostname: String,
    pub os: String,
    pub kernel: String,
    pub nixos_version: String,
    pub uptime_seconds: i64,
    pub boot_time: String,
    pub load: Vec<f64>,
    pub cpu: CpuInfo,
    pub memory: MemoryInfo,
    pub root_disk: DiskUsage,
    pub pools: Vec<PoolInfo>,
    pub temperatures: Vec<Temperature>,
    pub addresses: Vec<String>,
    pub generation: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tailscale: Option<TailscaleInfo>,
    pub services: ServiceCounts,
    pub capabilities: Capabilities,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct ServiceUnit {
    pub unit: String,
    pub load: String,
    pub active: String,
    pub sub: String,
    pub description: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Generation {
    pub number: i32,
    pub date: String,
    pub current: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct DatasetInfo {
    pub name: String,
    pub used: i64,
    pub available: i64,
    pub refer: i64,
    pub mountpoint: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct FilesystemInfo {
    pub source: String,
    pub fstype: String,
    pub size: i64,
    pub used: i64,
    pub available: i64,
    pub use_percent: f64,
    pub mountpoint: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct StorageSnapshot {
    pub pools: Vec<PoolInfo>,
    pub datasets: Vec<DatasetInfo>,
    pub filesystems: Vec<FilesystemInfo>,
}

/// One systemd-logind session on the host.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct LoginSession {
    pub id: String,
    pub user: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub uid: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seat: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tty: Option<String>,
    pub remote: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote_host: Option<String>,
    pub service: String,
    /// Session type reported by logind, for example `tty`, `x11` or `wayland`.
    pub kind: String,
    pub class: String,
    pub state: String,
    pub active: bool,
    pub started_at: String,
}

/// One command recovered from a user's shell history.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HistoryEntry {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub at: Option<String>,
    pub command: String,
}

/// One action performed in an application session.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SessionAction {
    pub id: String,
    pub at: String,
    pub action: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub job_id: Option<String>,
    /// Captured job output for long-running actions such as rebuilds.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status_code: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
}

/// Summary shown in the sessions list.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct SessionSummary {
    pub id: String,
    /// `app` for actions performed through the API, `login` for host sessions.
    pub kind: String,
    /// `web`, `ios`, `api`, `console`, `ssh` or `rdp`.
    pub source: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tty: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seat: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote_host: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub service: Option<String>,
    pub state: String,
    pub started_at: String,
    pub last_active_at: String,
    pub action_count: usize,
    /// `ok`, `mixed`, `failed` or `denied`.
    pub status: String,
    pub summary: String,
}

/// Full session detail: summary plus actions and logs.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SessionDetail {
    #[serde(flatten)]
    pub summary: SessionSummary,
    pub actions: Vec<SessionAction>,
    pub logs: Vec<String>,
    pub commands: Vec<HistoryEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SessionsResponse {
    pub sessions: Vec<SessionSummary>,
}
