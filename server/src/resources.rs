use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use chrono::{SecondsFormat, Utc};
use serde::{Deserialize, Serialize};

pub const SAMPLE_INTERVAL: Duration = Duration::from_secs(5);
const CLOCK_TICKS: f64 = 100.0;
const TOP_ENTRIES: usize = 40;
const TOP_PROCESSES: usize = 100;
const COMMAND_LIMIT: usize = 300;
/// One hour at the five-second sample interval.
const HISTORY_CAPACITY: usize = 720;
const MAX_HISTORY_SERIES: usize = 12;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct ResourceEntry {
    pub name: String,
    /// `service`, `machine`, `session`, `scope` or `app`.
    pub kind: String,
    pub unit: String,
    pub tasks: usize,
    pub cpu_percent: f64,
    pub memory_bytes: i64,
    pub read_bps: f64,
    pub write_bps: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct ProcessEntry {
    pub pid: i32,
    pub name: String,
    pub command: String,
    pub unit: String,
    pub kind: String,
    pub cpu_percent: f64,
    pub memory_bytes: i64,
    pub read_bps: f64,
    pub write_bps: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct ResourceUsage {
    pub at: String,
    pub interval_ms: u64,
    pub cpu_count: usize,
    pub memory_total: i64,
    pub total_cpu_percent: f64,
    pub total_memory_bytes: i64,
    pub total_read_bps: f64,
    pub total_write_bps: f64,
    pub services: Vec<ResourceEntry>,
    pub apps: Vec<ResourceEntry>,
    pub processes: Vec<ProcessEntry>,
}

pub trait ResourceProbe: Send + Sync {
    fn snapshot(&self) -> Option<ResourceUsage>;
    fn history(
        &self,
        _kind: &str,
        _minutes: i64,
        _metric: &str,
        _entities: &[String],
        _top: usize,
    ) -> ResourceHistory {
        ResourceHistory::default()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct ResourceSeriesPoint {
    pub at: String,
    pub cpu_percent: f64,
    pub memory_bytes: i64,
    pub read_bps: f64,
    pub write_bps: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct ResourceSeries {
    pub key: String,
    pub name: String,
    pub kind: String,
    pub points: Vec<ResourceSeriesPoint>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct ResourceHistory {
    pub from: String,
    pub to: String,
    pub kind: String,
    pub series: Vec<ResourceSeries>,
    pub totals: Vec<ResourceSeriesPoint>,
}

#[derive(Clone)]
struct HistorySample {
    at: String,
    total_cpu_percent: f64,
    total_memory_bytes: i64,
    total_read_bps: f64,
    total_write_bps: f64,
    services: Vec<ResourceEntry>,
    apps: Vec<ResourceEntry>,
}

#[derive(Debug, Clone, Copy)]
struct Counters {
    ticks: u64,
    read_bytes: u64,
    write_bytes: u64,
}

#[derive(Default)]
struct Inner {
    previous: HashMap<i32, Counters>,
    sampled_at: Option<Instant>,
    snapshot: Option<ResourceUsage>,
    history: std::collections::VecDeque<HistorySample>,
}

pub struct ResourceMonitor {
    inner: Mutex<Inner>,
}

impl Default for ResourceMonitor {
    fn default() -> Self {
        Self::new()
    }
}

impl ResourceMonitor {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(Inner::default()),
        }
    }

    /// Read `/proc` and publish a new snapshot. The first call has no CPU or
    /// I/O deltas yet; later calls are relative to the previous sample.
    pub fn sample(&self) -> Option<ResourceUsage> {
        let started = Instant::now();
        let raw = read_processes();
        if raw.is_empty() {
            return None;
        }

        let mut inner = self.inner.lock().expect("resource monitor poisoned");
        let elapsed_secs = inner
            .sampled_at
            .map(|previous| started.duration_since(previous).as_secs_f64())
            .unwrap_or(0.0);
        let cpu_count = num_cpus::get().max(1);
        let memory_total = read_memory_total();
        let max_ticks = elapsed_secs * CLOCK_TICKS * cpu_count as f64 * 1.5;

        let mut processes = Vec::with_capacity(raw.len());
        let mut previous = HashMap::with_capacity(raw.len());
        for process in &raw {
            let counters = Counters {
                ticks: process.ticks,
                read_bytes: process.read_bytes,
                write_bytes: process.write_bytes,
            };
            let (cpu_percent, read_bps, write_bps) = if elapsed_secs > 0.0 {
                match inner.previous.get(&process.pid) {
                    Some(old) => {
                        let delta_ticks = process.ticks.saturating_sub(old.ticks) as f64;
                        let delta_read = process.read_bytes.saturating_sub(old.read_bytes) as f64;
                        let delta_write =
                            process.write_bytes.saturating_sub(old.write_bytes) as f64;
                        let cpu = if delta_ticks > max_ticks {
                            // PID reuse or a counter reset.
                            0.0
                        } else {
                            delta_ticks / CLOCK_TICKS / elapsed_secs * 100.0
                        };
                        (cpu, delta_read / elapsed_secs, delta_write / elapsed_secs)
                    }
                    None => (0.0, 0.0, 0.0),
                }
            } else {
                (0.0, 0.0, 0.0)
            };

            previous.insert(process.pid, counters);
            processes.push(ProcessEntry {
                pid: process.pid,
                name: process.name.clone(),
                command: process.command.clone(),
                unit: process.unit.clone(),
                kind: process.kind.clone(),
                cpu_percent,
                memory_bytes: process.memory_bytes,
                read_bps,
                write_bps,
            });
        }

        inner.previous = previous;
        inner.sampled_at = Some(started);

        let usage = build_usage(
            processes,
            cpu_count,
            memory_total,
            (elapsed_secs * 1000.0) as u64,
        );
        inner.history.push_back(HistorySample {
            at: usage.at.clone(),
            total_cpu_percent: usage.total_cpu_percent,
            total_memory_bytes: usage.total_memory_bytes,
            total_read_bps: usage.total_read_bps,
            total_write_bps: usage.total_write_bps,
            services: usage.services.clone(),
            apps: usage.apps.clone(),
        });
        while inner.history.len() > HISTORY_CAPACITY {
            inner.history.pop_front();
        }
        inner.snapshot = Some(usage.clone());
        Some(usage)
    }

    pub fn snapshot(&self) -> Option<ResourceUsage> {
        self.inner
            .lock()
            .expect("resource monitor poisoned")
            .snapshot
            .clone()
    }

    pub fn history(
        &self,
        kind: &str,
        minutes: i64,
        metric: &str,
        entities: &[String],
        top: usize,
    ) -> ResourceHistory {
        let now = Utc::now();
        let cutoff = (now - chrono::Duration::minutes(minutes.clamp(1, 60)))
            .to_rfc3339_opts(SecondsFormat::Secs, true);
        let inner = self.inner.lock().expect("resource monitor poisoned");
        let samples: Vec<HistorySample> = inner
            .history
            .iter()
            .filter(|sample| sample.at >= cutoff)
            .cloned()
            .collect();
        if samples.is_empty() {
            let at = now.to_rfc3339_opts(SecondsFormat::Secs, true);
            return ResourceHistory {
                from: at.clone(),
                to: at,
                kind: kind.to_string(),
                ..ResourceHistory::default()
            };
        }
        build_history(&samples, kind, metric, entities, top)
    }
}

impl ResourceProbe for ResourceMonitor {
    fn snapshot(&self) -> Option<ResourceUsage> {
        ResourceMonitor::snapshot(self)
    }

    fn history(
        &self,
        kind: &str,
        minutes: i64,
        metric: &str,
        entities: &[String],
        top: usize,
    ) -> ResourceHistory {
        ResourceMonitor::history(self, kind, minutes, metric, entities, top)
    }
}

struct RawProcess {
    pid: i32,
    name: String,
    command: String,
    unit: String,
    kind: String,
    ticks: u64,
    memory_bytes: i64,
    read_bytes: u64,
    write_bytes: u64,
}

fn read_processes() -> Vec<RawProcess> {
    let Ok(entries) = fs::read_dir("/proc") else {
        return Vec::new();
    };

    let mut processes = Vec::new();
    for entry in entries.flatten() {
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|value| value.parse::<i32>().ok())
        else {
            continue;
        };
        let base = Path::new("/proc").join(pid.to_string());
        let Ok(stat) = fs::read_to_string(base.join("stat")) else {
            continue;
        };
        let Some((_parsed_pid, comm, ticks)) = parse_stat(&stat) else {
            continue;
        };

        let status = fs::read_to_string(base.join("status")).unwrap_or_default();
        let memory_bytes = parse_vm_rss(&status);
        let cgroup = fs::read_to_string(base.join("cgroup"))
            .ok()
            .and_then(|contents| parse_cgroup(&contents))
            .unwrap_or_else(|| "/".to_string());
        let (unit, kind, _unit_name) = unit_info(&cgroup);

        let executable = fs::read_link(base.join("exe")).ok().and_then(|path| {
            path.file_name()
                .map(|name| name.to_string_lossy().into_owned())
        });
        let name = process_name(executable.as_deref(), &comm);
        let command = read_command(&base, &comm);

        let io = fs::read_to_string(base.join("io")).unwrap_or_default();
        let (read_bytes, write_bytes) = parse_io(&io);

        processes.push(RawProcess {
            pid,
            name,
            command,
            unit,
            kind,
            ticks,
            memory_bytes,
            read_bytes,
            write_bytes,
        });
    }
    processes
}

fn parse_stat(contents: &str) -> Option<(i32, String, u64)> {
    let (pid, rest) = contents.split_once('(')?;
    let pid = pid.trim().parse::<i32>().ok()?;
    let (comm, rest) = rest.rsplit_once(')')?;
    let fields: Vec<&str> = rest.split_whitespace().collect();
    let utime = fields.get(11)?.parse::<u64>().ok()?;
    let stime = fields.get(12)?.parse::<u64>().ok()?;
    Some((pid, comm.to_string(), utime + stime))
}

fn parse_vm_rss(status: &str) -> i64 {
    status
        .lines()
        .find_map(|line| {
            let value = line.strip_prefix("VmRSS:")?;
            value
                .split_whitespace()
                .next()
                .and_then(|value| value.parse::<i64>().ok())
        })
        .map(|kilobytes| kilobytes * 1024)
        .unwrap_or(0)
}

fn parse_cgroup(contents: &str) -> Option<String> {
    contents
        .lines()
        .find_map(|line| line.strip_prefix("0::").map(str::to_string))
}

fn parse_io(contents: &str) -> (u64, u64) {
    let mut read = 0;
    let mut write = 0;
    for line in contents.lines() {
        if let Some(value) = line.strip_prefix("read_bytes:") {
            read = value.trim().parse().unwrap_or(0);
        } else if let Some(value) = line.strip_prefix("write_bytes:") {
            write = value.trim().parse().unwrap_or(0);
        }
    }
    (read, write)
}

fn read_command(base: &Path, comm: &str) -> String {
    let bytes = fs::read(base.join("cmdline")).unwrap_or_default();
    let mut parts = Vec::new();
    for part in bytes.split(|byte| *byte == 0) {
        if part.is_empty() {
            continue;
        }
        parts.push(String::from_utf8_lossy(part).into_owned());
    }
    let command = parts.join(" ");
    if command.trim().is_empty() {
        return format!("[{comm}]");
    }
    command.chars().take(COMMAND_LIMIT).collect()
}

fn process_name(executable: Option<&str>, comm: &str) -> String {
    let candidate = executable.unwrap_or(comm).trim_start_matches('.');
    let candidate = candidate.strip_suffix("-wrapped").unwrap_or(candidate);
    if candidate.is_empty() {
        "unknown".to_string()
    } else {
        candidate.to_string()
    }
}

fn decode_cgroup(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut decoded = String::with_capacity(value.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'\\' && index + 3 < bytes.len() && bytes[index + 1] == b'x' {
            if let Ok(byte) = u8::from_str_radix(&value[index + 2..index + 4], 16) {
                decoded.push(byte as char);
                index += 4;
                continue;
            }
        }
        decoded.push(bytes[index] as char);
        index += 1;
    }
    decoded
}

fn unit_info(path: &str) -> (String, String, String) {
    if path.trim_matches('/').is_empty() {
        // Kernel threads live in the root cgroup.
        return (
            "kernel".to_string(),
            "kernel".to_string(),
            "kernel".to_string(),
        );
    }
    let components: Vec<&str> = path
        .trim_start_matches('/')
        .split('/')
        .filter(|component| !component.is_empty())
        .collect();
    let component = components
        .iter()
        .rev()
        .find(|component| component.ends_with(".service") || component.ends_with(".scope"))
        .copied()
        .or_else(|| components.last().copied())
        .unwrap_or("init.scope");
    let unit = decode_cgroup(component);
    let stem = unit
        .strip_suffix(".service")
        .or_else(|| unit.strip_suffix(".scope"))
        .unwrap_or(&unit);

    let kind = if unit.ends_with(".service") {
        "service"
    } else if stem.starts_with("session-") {
        "session"
    } else if stem.starts_with("app-") {
        "app"
    } else if path.contains("/machine.slice/") {
        "machine"
    } else {
        "scope"
    };

    let name = if let Some(rest) = stem.strip_prefix("machine-qemu-") {
        rest.split_once('-')
            .map(|(_id, name)| name)
            .unwrap_or(rest)
            .to_string()
    } else {
        stem.strip_prefix("app-").unwrap_or(stem).to_string()
    };

    (unit, kind.to_string(), name)
}

fn read_memory_total() -> i64 {
    fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|contents| {
            contents.lines().find_map(|line| {
                let value = line.strip_prefix("MemTotal:")?;
                value
                    .split_whitespace()
                    .next()
                    .and_then(|value| value.parse::<i64>().ok())
            })
        })
        .map(|kilobytes| kilobytes * 1024)
        .unwrap_or(0)
}

fn build_usage(
    processes: Vec<ProcessEntry>,
    cpu_count: usize,
    memory_total: i64,
    interval_ms: u64,
) -> ResourceUsage {
    let total_cpu_percent = processes.iter().map(|process| process.cpu_percent).sum();
    let total_memory_bytes = processes.iter().map(|process| process.memory_bytes).sum();
    let total_read_bps = processes.iter().map(|process| process.read_bps).sum();
    let total_write_bps = processes.iter().map(|process| process.write_bps).sum();

    let mut services: HashMap<String, ResourceEntry> = HashMap::new();
    let mut apps: HashMap<String, ResourceEntry> = HashMap::new();

    for process in &processes {
        let service = services
            .entry(process.unit.clone())
            .or_insert_with(|| ResourceEntry {
                name: process.name.clone(),
                kind: process.kind.clone(),
                unit: process.unit.clone(),
                ..ResourceEntry::default()
            });
        // Prefer the unit's friendly name over the executable for services.
        let (_unit, _kind, friendly) = unit_info(&process.unit);
        if !friendly.is_empty() {
            service.name = friendly;
        }
        service.tasks += 1;
        service.cpu_percent += process.cpu_percent;
        service.memory_bytes += process.memory_bytes;
        service.read_bps += process.read_bps;
        service.write_bps += process.write_bps;

        let app = apps
            .entry(process.name.clone())
            .or_insert_with(|| ResourceEntry {
                name: process.name.clone(),
                kind: "app".to_string(),
                unit: process.unit.clone(),
                ..ResourceEntry::default()
            });
        app.tasks += 1;
        app.cpu_percent += process.cpu_percent;
        app.memory_bytes += process.memory_bytes;
        app.read_bps += process.read_bps;
        app.write_bps += process.write_bps;
    }

    let services = top_entries(services.into_values().collect());
    let apps = top_entries(apps.into_values().collect());
    let processes = top_processes(processes);

    ResourceUsage {
        at: Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
        interval_ms,
        cpu_count,
        memory_total,
        total_cpu_percent,
        total_memory_bytes,
        total_read_bps,
        total_write_bps,
        services,
        apps,
        processes,
    }
}

fn top_entries(mut entries: Vec<ResourceEntry>) -> Vec<ResourceEntry> {
    if entries.len() <= TOP_ENTRIES {
        entries.sort_by(|left, right| right.cpu_percent.total_cmp(&left.cpu_percent));
        return entries;
    }

    entries.sort_by(|left, right| right.cpu_percent.total_cmp(&left.cpu_percent));
    let mut selected: HashMap<String, ResourceEntry> = entries
        .iter()
        .take(TOP_ENTRIES)
        .map(|entry| (entry.unit.clone() + "\u{0}" + &entry.name, entry.clone()))
        .collect();

    entries.sort_by(|left, right| right.memory_bytes.cmp(&left.memory_bytes));
    for entry in entries.iter().take(TOP_ENTRIES) {
        selected
            .entry(entry.unit.clone() + "\u{0}" + &entry.name)
            .or_insert_with(|| entry.clone());
    }

    let mut values: Vec<ResourceEntry> = selected.into_values().collect();
    values.sort_by(|left, right| right.cpu_percent.total_cmp(&left.cpu_percent));
    values
}

fn top_processes(mut processes: Vec<ProcessEntry>) -> Vec<ProcessEntry> {
    if processes.len() <= TOP_PROCESSES {
        processes.sort_by(|left, right| right.cpu_percent.total_cmp(&left.cpu_percent));
        return processes;
    }

    processes.sort_by(|left, right| right.cpu_percent.total_cmp(&left.cpu_percent));
    let mut selected: HashMap<i32, ProcessEntry> = processes
        .iter()
        .take(TOP_PROCESSES)
        .map(|process| (process.pid, process.clone()))
        .collect();

    processes.sort_by(|left, right| right.memory_bytes.cmp(&left.memory_bytes));
    for process in processes.iter().take(TOP_PROCESSES) {
        selected
            .entry(process.pid)
            .or_insert_with(|| process.clone());
    }

    let mut values: Vec<ProcessEntry> = selected.into_values().collect();
    values.sort_by(|left, right| right.cpu_percent.total_cmp(&left.cpu_percent));
    values
}

fn entries_for<'a>(sample: &'a HistorySample, kind: &str) -> &'a [ResourceEntry] {
    if kind == "apps" {
        &sample.apps
    } else {
        &sample.services
    }
}

fn entity_key(entry: &ResourceEntry, kind: &str) -> String {
    if kind == "apps" {
        entry.name.clone()
    } else {
        entry.unit.clone()
    }
}

fn metric_value(entry: &ResourceEntry, metric: &str) -> f64 {
    match metric {
        "memory" => entry.memory_bytes as f64,
        "read" => entry.read_bps,
        "write" => entry.write_bps,
        _ => entry.cpu_percent,
    }
}

fn series_point(sample: &HistorySample, entry: Option<&ResourceEntry>) -> ResourceSeriesPoint {
    ResourceSeriesPoint {
        at: sample.at.clone(),
        cpu_percent: entry.map(|entry| entry.cpu_percent).unwrap_or(0.0),
        memory_bytes: entry.map(|entry| entry.memory_bytes).unwrap_or(0),
        read_bps: entry.map(|entry| entry.read_bps).unwrap_or(0.0),
        write_bps: entry.map(|entry| entry.write_bps).unwrap_or(0.0),
    }
}

fn build_history(
    samples: &[HistorySample],
    kind: &str,
    metric: &str,
    entities: &[String],
    top: usize,
) -> ResourceHistory {
    let kind = if kind == "apps" { "apps" } else { "services" };
    let top = top.clamp(1, MAX_HISTORY_SERIES);
    let mut selected: Vec<(String, String, String)> = Vec::new();

    if entities.is_empty() {
        let mut ranking: HashMap<String, (String, String, f64)> = HashMap::new();
        for sample in samples {
            for entry in entries_for(sample, kind) {
                let key = entity_key(entry, kind);
                let score = metric_value(entry, metric);
                let candidate = ranking
                    .entry(key)
                    .or_insert_with(|| (entry.name.clone(), entry.kind.clone(), score));
                if score > candidate.2 {
                    candidate.0 = entry.name.clone();
                    candidate.1 = entry.kind.clone();
                    candidate.2 = score;
                }
            }
        }
        let mut ranked: Vec<(String, String, String, f64)> = ranking
            .into_iter()
            .map(|(key, (name, entity_kind, score))| (key, name, entity_kind, score))
            .collect();
        ranked.sort_by(|left, right| right.3.total_cmp(&left.3));
        for (key, name, entity_kind, _) in ranked.into_iter().take(top) {
            selected.push((key, name, entity_kind));
        }
    } else {
        let mut seen = std::collections::HashSet::new();
        for key in entities
            .iter()
            .map(|value| value.trim())
            .filter(|value| !value.is_empty())
        {
            if !seen.insert(key.to_string()) {
                continue;
            }
            let found = samples.iter().find_map(|sample| {
                entries_for(sample, kind)
                    .iter()
                    .find(|entry| entity_key(entry, kind) == key)
                    .map(|entry| (entry.name.clone(), entry.kind.clone()))
            });
            let (name, entity_kind) = found.unwrap_or_else(|| {
                (
                    key.to_string(),
                    if kind == "apps" {
                        "app".to_string()
                    } else {
                        "service".to_string()
                    },
                )
            });
            selected.push((key.to_string(), name, entity_kind));
            if selected.len() >= MAX_HISTORY_SERIES {
                break;
            }
        }
    }

    let series = selected
        .into_iter()
        .map(|(key, name, entity_kind)| {
            let points = samples
                .iter()
                .map(|sample| {
                    let entry = entries_for(sample, kind)
                        .iter()
                        .find(|entry| entity_key(entry, kind) == key);
                    series_point(sample, entry)
                })
                .collect();
            ResourceSeries {
                key,
                name,
                kind: entity_kind,
                points,
            }
        })
        .collect();

    let totals = samples
        .iter()
        .map(|sample| ResourceSeriesPoint {
            at: sample.at.clone(),
            cpu_percent: sample.total_cpu_percent,
            memory_bytes: sample.total_memory_bytes,
            read_bps: sample.total_read_bps,
            write_bps: sample.total_write_bps,
        })
        .collect();

    ResourceHistory {
        from: samples
            .first()
            .map(|sample| sample.at.clone())
            .unwrap_or_default(),
        to: samples
            .last()
            .map(|sample| sample.at.clone())
            .unwrap_or_default(),
        kind: kind.to_string(),
        series,
        totals,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_proc_stat() {
        let stat = "123 (bash) S 1 2 3 4 5 6 7 8 9 10 100 200 0 0\n";
        let (pid, comm, ticks) = parse_stat(stat).unwrap();
        assert_eq!(pid, 123);
        assert_eq!(comm, "bash");
        assert_eq!(ticks, 300);
    }

    #[test]
    fn parses_memory_io_and_cgroup() {
        assert_eq!(
            parse_vm_rss("Name:\tbash\nVmRSS:\t  2048 kB\n"),
            2_048 * 1024
        );
        assert_eq!(
            parse_cgroup("0::/system.slice/nginx.service\n"),
            Some("/system.slice/nginx.service".to_string())
        );
        let (read, write) = parse_io("read_bytes: 100\nwrite_bytes: 200\n");
        assert_eq!((read, write), (100, 200));
    }

    #[test]
    fn derives_unit_names_and_kinds() {
        assert_eq!(
            unit_info("/"),
            (
                "kernel".to_string(),
                "kernel".to_string(),
                "kernel".to_string()
            )
        );
        assert_eq!(
            unit_info("/system.slice/nginx.service"),
            (
                "nginx.service".to_string(),
                "service".to_string(),
                "nginx".to_string()
            )
        );
        assert_eq!(
            unit_info("/user.slice/user-1000.slice/session-1.scope"),
            (
                "session-1.scope".to_string(),
                "session".to_string(),
                "session-1".to_string()
            )
        );
        assert_eq!(
            unit_info(
                "/machine.slice/machine-qemu\\x2d8\\x2dwin11\\x2dstock.scope/libvirt/emulator"
            ),
            (
                "machine-qemu-8-win11-stock.scope".to_string(),
                "machine".to_string(),
                "win11-stock".to_string()
            )
        );
        assert_eq!(
            unit_info(
                "/user.slice/user-1000.slice/user@1000.service/app.slice/app-firefox-1.scope"
            ),
            (
                "app-firefox-1.scope".to_string(),
                "app".to_string(),
                "firefox-1".to_string()
            )
        );
    }

    fn sample_entry(name: &str, unit: &str, cpu: f64, memory: i64) -> ResourceEntry {
        ResourceEntry {
            name: name.to_string(),
            kind: "service".to_string(),
            unit: unit.to_string(),
            tasks: 1,
            cpu_percent: cpu,
            memory_bytes: memory,
            read_bps: 0.0,
            write_bps: 0.0,
        }
    }

    fn history_sample(at: &str, services: Vec<ResourceEntry>) -> HistorySample {
        HistorySample {
            at: at.to_string(),
            total_cpu_percent: services.iter().map(|entry| entry.cpu_percent).sum(),
            total_memory_bytes: services.iter().map(|entry| entry.memory_bytes).sum(),
            total_read_bps: 0.0,
            total_write_bps: 0.0,
            services,
            apps: Vec::new(),
        }
    }

    #[test]
    fn builds_top_entity_history() {
        let samples = vec![
            history_sample(
                "2026-01-01T00:00:00Z",
                vec![
                    sample_entry("nginx", "nginx.service", 10.0, 100),
                    sample_entry("db", "db.service", 30.0, 50),
                ],
            ),
            history_sample(
                "2026-01-01T00:00:05Z",
                vec![
                    sample_entry("nginx", "nginx.service", 20.0, 120),
                    sample_entry("db", "db.service", 5.0, 60),
                ],
            ),
        ];

        let history = build_history(&samples, "services", "cpu", &[], 1);
        assert_eq!(history.kind, "services");
        assert_eq!(history.series.len(), 1);
        assert_eq!(history.series[0].key, "db.service");
        assert_eq!(history.series[0].points.len(), 2);
        assert_eq!(history.series[0].points[0].cpu_percent, 30.0);
        assert_eq!(history.totals.len(), 2);
        assert_eq!(history.from, "2026-01-01T00:00:00Z");
        assert_eq!(history.to, "2026-01-01T00:00:05Z");
    }

    #[test]
    fn history_can_select_explicit_entities() {
        let samples = vec![
            history_sample(
                "2026-01-01T00:00:00Z",
                vec![sample_entry("nginx", "nginx.service", 10.0, 100)],
            ),
            history_sample(
                "2026-01-01T00:00:05Z",
                vec![sample_entry("nginx", "nginx.service", 20.0, 120)],
            ),
        ];
        let history = build_history(
            &samples,
            "services",
            "cpu",
            &["nginx.service".to_string()],
            1,
        );
        assert_eq!(history.series.len(), 1);
        assert_eq!(history.series[0].name, "nginx");
        assert_eq!(history.series[0].points[1].memory_bytes, 120);
    }

    #[test]
    fn process_names_strip_wrappers_and_dots() {
        assert_eq!(
            process_name(Some(".xfce4-terminal-wrapped"), "x"),
            "xfce4-terminal"
        );
        assert_eq!(process_name(None, ".qemu-system-x8"), "qemu-system-x8");
    }
}
