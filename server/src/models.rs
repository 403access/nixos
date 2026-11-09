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
