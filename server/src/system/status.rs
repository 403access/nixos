use std::collections::HashMap;
use std::path::{Path, PathBuf};

use chrono::{Duration as ChronoDuration, SecondsFormat, Utc};

use crate::commands::CommandRunner;
use crate::models::{Capabilities, CpuInfo, MemoryInfo, Status, Temperature};
use crate::util::{parse_f64, parse_i64, read_file_trim, round1, split_lines, unquote};

use super::cpu::CpuSampler;
use super::{addresses, generations, services, storage, tailscale, SystemPaths};

pub fn collect_status(
    runner: &dyn CommandRunner,
    paths: &SystemPaths,
    version: &str,
    allow_rebuild: bool,
    allow_power: bool,
    cpu: &CpuSampler,
) -> Status {
    let hostname = gethostname::gethostname().to_string_lossy().to_string();
    let os_release = parse_os_release(&read_file_trim(paths.etc_dir.join("os-release")));

    let uptime_seconds = {
        let uptime = read_file_trim(paths.proc_dir.join("uptime"));
        let fields: Vec<&str> = uptime.split_whitespace().collect();
        fields
            .first()
            .map(|value| parse_f64(value) as i64)
            .unwrap_or(0)
    };

    let load = parse_load(&read_file_trim(paths.proc_dir.join("loadavg")));

    let mut kernel = read_file_trim(paths.proc_dir.join("sys/kernel/osrelease"));
    if kernel.is_empty() {
        let result = runner.run("uname", &["-r"], std::time::Duration::from_secs(3));
        if result.error.is_none() {
            kernel = result.output.trim().to_string();
        }
    }

    let mut nixos_version = read_file_trim(paths.run_dir.join("current-system/nixos-version"));
    if nixos_version.is_empty() {
        let result = runner.run("nixos-version", &[], std::time::Duration::from_secs(5));
        if result.error.is_none() {
            nixos_version = result.output.trim().to_string();
        }
    }
    if nixos_version.is_empty() {
        nixos_version = os_release.get("VERSION").cloned().unwrap_or_default();
    }
    if nixos_version.is_empty() {
        nixos_version = os_release.get("PRETTY_NAME").cloned().unwrap_or_default();
    }

    let boot_time = (Utc::now() - ChronoDuration::seconds(uptime_seconds))
        .to_rfc3339_opts(SecondsFormat::Secs, true);

    let cpu_info = CpuInfo {
        model: parse_cpu_model(&read_file_trim(paths.proc_dir.join("cpuinfo"))),
        cores: num_cpus::get(),
        usage_percent: cpu.usage_percent(),
    };

    Status {
        server_version: version.to_string(),
        hostname,
        os: os_release.get("PRETTY_NAME").cloned().unwrap_or_default(),
        kernel,
        nixos_version,
        uptime_seconds,
        boot_time,
        load,
        cpu: cpu_info,
        memory: parse_meminfo(&read_file_trim(paths.proc_dir.join("meminfo"))),
        root_disk: storage::collect_root_disk(runner),
        pools: storage::collect_pools(runner),
        temperatures: collect_temperatures(&paths.sys_dir),
        addresses: addresses::collect_addresses(),
        generation: generations::read_generation(paths),
        tailscale: Some(tailscale::collect_tailscale(runner)),
        services: services::collect_service_counts(runner),
        capabilities: Capabilities {
            services: true,
            rebuild: allow_rebuild,
            power: allow_power,
        },
    }
}

pub fn parse_os_release(content: &str) -> HashMap<String, String> {
    let mut result = HashMap::new();
    for line in split_lines(content) {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        result.insert(key.trim().to_string(), unquote(value));
    }
    result
}

pub fn parse_load(content: &str) -> Vec<f64> {
    let fields: Vec<&str> = content.split_whitespace().collect();
    let mut load = vec![0.0, 0.0, 0.0];
    for (index, slot) in load.iter_mut().enumerate() {
        if let Some(field) = fields.get(index) {
            *slot = parse_f64(field);
        }
    }
    load
}

pub fn parse_cpu_model(content: &str) -> String {
    for line in split_lines(content) {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        match key.trim() {
            "model name" | "Hardware" | "Processor" => {
                let model = value.trim();
                if !model.is_empty() {
                    return model.to_string();
                }
            }
            _ => {}
        }
    }
    "Unknown CPU".to_string()
}

pub fn parse_meminfo(content: &str) -> MemoryInfo {
    let mut values: HashMap<String, i64> = HashMap::new();
    for line in split_lines(content) {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let Some(first) = value.split_whitespace().next() else {
            continue;
        };
        values.insert(key.trim().to_string(), parse_i64(first) * 1024);
    }

    let total = values.get("MemTotal").copied().unwrap_or(0);
    let free = values.get("MemFree").copied().unwrap_or(0);
    let mut available = values.get("MemAvailable").copied().unwrap_or(0);
    if available == 0 {
        available = free
            + values.get("Buffers").copied().unwrap_or(0)
            + values.get("Cached").copied().unwrap_or(0)
            + values.get("SReclaimable").copied().unwrap_or(0);
    }
    let used = (total - available).max(0);
    let swap_total = values.get("SwapTotal").copied().unwrap_or(0);
    let swap_free = values.get("SwapFree").copied().unwrap_or(0);
    let swap_used = (swap_total - swap_free).max(0);

    MemoryInfo {
        total,
        used,
        free,
        available,
        cached: values.get("Cached").copied().unwrap_or(0)
            + values.get("SReclaimable").copied().unwrap_or(0),
        swap_total,
        swap_used,
    }
}

pub fn collect_temperatures(sys_dir: &Path) -> Vec<Temperature> {
    let pattern = format!("{}/class/hwmon/hwmon*/temp*_input", sys_dir.display());
    let mut results = Vec::new();
    let mut seen: HashMap<String, u32> = HashMap::new();

    let Ok(paths) = glob::glob(&pattern) else {
        return results;
    };

    for path in paths.flatten() {
        let celsius = parse_i64(&read_file_trim(&path)) as f64 / 1000.0;
        if !(-20.0..=150.0).contains(&celsius) {
            continue;
        }

        let directory = path.parent().unwrap_or_else(|| Path::new(""));
        let stem = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let label_name = format!("{}_label", stem.trim_end_matches("_input"));
        let mut label = read_file_trim(directory.join(&label_name));
        if label.is_empty() {
            label = read_file_trim(directory.join("name"));
        }
        if label.is_empty() {
            label = directory
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default();
        }

        let count = seen.entry(label.clone()).or_insert(0);
        *count += 1;
        if *count > 1 {
            label = format!("{label} #{count}");
        }

        results.push(Temperature {
            label,
            celsius: round1(celsius),
        });
    }

    results.sort_by(|left, right| {
        right
            .celsius
            .partial_cmp(&left.celsius)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    results.truncate(12);
    results
}

/// Kept for tests that need the conventional roots without a full server.
pub fn default_paths() -> SystemPaths {
    SystemPaths {
        proc_dir: PathBuf::from("/proc"),
        sys_dir: PathBuf::from("/sys"),
        etc_dir: PathBuf::from("/etc"),
        run_dir: PathBuf::from("/run"),
        nix_profiles: PathBuf::from("/nix/var/nix/profiles"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_meminfo_like_the_go_server() {
        let content = "\
MemTotal:       16384000 kB
MemFree:         2048000 kB
MemAvailable:   12288000 kB
Buffers:          512000 kB
Cached:          4096000 kB
SReclaimable:     512000 kB
SwapTotal:       4096000 kB
SwapFree:        3072000 kB
";
        let memory = parse_meminfo(content);

        assert_eq!(memory.total, 16_384_000 * 1024);
        assert_eq!(memory.used, (16_384_000 - 12_288_000) * 1024);
        assert_eq!(memory.swap_used, 1_024_000 * 1024);
        assert_eq!(memory.cached, (4_096_000 + 512_000) * 1024);
    }

    #[test]
    fn meminfo_falls_back_when_available_is_missing() {
        let memory = parse_meminfo(
            "MemTotal: 1000 kB\nMemFree: 100 kB\nBuffers: 10 kB\nCached: 20 kB\nSReclaimable: 5 kB\n",
        );
        assert_eq!(memory.available, 135 * 1024);
        assert_eq!(memory.used, 865 * 1024);
    }

    #[test]
    fn parses_load() {
        let load = parse_load("0.52 0.61 0.73 2/412 12345\n");
        assert_eq!(load, vec![0.52, 0.61, 0.73]);
    }

    #[test]
    fn parse_load_pads_missing_values() {
        assert_eq!(parse_load("0.5"), vec![0.5, 0.0, 0.0]);
        assert_eq!(parse_load(""), vec![0.0, 0.0, 0.0]);
    }

    #[test]
    fn parses_os_release() {
        let release = parse_os_release(
            "PRETTY_NAME=\"NixOS 25.05 (Xantusia)\"\nVERSION_ID=25.05\n# comment\n",
        );
        assert_eq!(
            release.get("PRETTY_NAME").map(String::as_str),
            Some("NixOS 25.05 (Xantusia)")
        );
        assert_eq!(release.get("VERSION_ID").map(String::as_str), Some("25.05"));
    }

    #[test]
    fn parses_cpu_models_for_common_platforms() {
        assert_eq!(
            parse_cpu_model("processor\t: 0\nmodel name\t: AMD Ryzen 9 5900X\n"),
            "AMD Ryzen 9 5900X"
        );
        assert_eq!(parse_cpu_model("Hardware\t: BCM2711\n"), "BCM2711");
        assert_eq!(parse_cpu_model(""), "Unknown CPU");
    }

    #[test]
    fn collects_and_sorts_temperatures_with_deduped_labels() {
        let directory = tempfile::tempdir().expect("tempdir");
        let sys = directory.path();
        let hwmon = sys.join("class/hwmon");
        std::fs::create_dir_all(hwmon.join("hwmon0")).unwrap();
        std::fs::create_dir_all(hwmon.join("hwmon1")).unwrap();

        std::fs::write(hwmon.join("hwmon0/temp1_input"), "45000\n").unwrap();
        std::fs::write(hwmon.join("hwmon0/temp1_label"), "Package\n").unwrap();
        std::fs::write(hwmon.join("hwmon0/temp2_input"), "65000\n").unwrap();
        std::fs::write(hwmon.join("hwmon0/temp2_label"), "Package\n").unwrap();
        std::fs::write(hwmon.join("hwmon1/temp1_input"), "999000\n").unwrap();
        std::fs::write(hwmon.join("hwmon1/temp2_input"), "38500\n").unwrap();
        std::fs::write(hwmon.join("hwmon1/name"), "nvme\n").unwrap();

        let temperatures = collect_temperatures(sys);
        assert_eq!(temperatures.len(), 3);
        assert_eq!(temperatures[0].label, "Package #2");
        assert_eq!(temperatures[0].celsius, 65.0);
        assert_eq!(temperatures[1].label, "Package");
        assert_eq!(temperatures[1].celsius, 45.0);
        assert_eq!(temperatures[2].label, "nvme");
        assert_eq!(temperatures[2].celsius, 38.5);
    }

    #[test]
    fn temperatures_are_capped_at_twelve() {
        let directory = tempfile::tempdir().expect("tempdir");
        let hwmon = directory.path().join("class/hwmon/hwmon0");
        std::fs::create_dir_all(&hwmon).unwrap();
        for index in 0..20 {
            std::fs::write(hwmon.join(format!("temp{index}_input")), "30000\n").unwrap();
        }
        let temperatures = collect_temperatures(directory.path());
        assert_eq!(temperatures.len(), 12);
    }

    #[test]
    fn default_paths_match_the_host_layout() {
        let paths = default_paths();
        assert_eq!(paths.proc_dir, PathBuf::from("/proc"));
        assert_eq!(paths.nix_profiles, PathBuf::from("/nix/var/nix/profiles"));
    }
}
