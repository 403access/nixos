use std::path::PathBuf;
use std::sync::Mutex;

use crate::util::{parse_u64, read_file_trim, round1, split_lines};

/// Samples aggregate CPU utilisation from `/proc/stat`, reporting the delta
/// between consecutive calls like the Go server.
pub struct CpuSampler {
    path: PathBuf,
    state: Mutex<CpuState>,
}

struct CpuState {
    prev_total: u64,
    prev_idle: u64,
    primed: bool,
}

impl CpuSampler {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            state: Mutex::new(CpuState {
                prev_total: 0,
                prev_idle: 0,
                primed: false,
            }),
        }
    }

    /// Capture an initial reading so the first status request has a delta.
    pub fn prime(&self) {
        let _ = self.usage_percent();
    }

    pub fn usage_percent(&self) -> f64 {
        let (total, idle) = parse_cpu_times(&read_file_trim(&self.path));
        if total == 0 {
            return 0.0;
        }

        let mut state = self.state.lock().expect("cpu sampler poisoned");
        if !state.primed {
            state.prev_total = total;
            state.prev_idle = idle;
            state.primed = true;
            return 0.0;
        }

        let delta_total = total.saturating_sub(state.prev_total);
        let delta_idle = idle.saturating_sub(state.prev_idle);
        state.prev_total = total;
        state.prev_idle = idle;

        if delta_total == 0 {
            return 0.0;
        }
        let usage = 100.0 * (delta_total.saturating_sub(delta_idle)) as f64 / delta_total as f64;
        round1(usage.clamp(0.0, 100.0))
    }
}

pub fn parse_cpu_times(content: &str) -> (u64, u64) {
    for line in split_lines(content) {
        if !line.starts_with("cpu ") {
            continue;
        }
        let fields: Vec<&str> = line.split_whitespace().collect();
        let mut total = 0u64;
        let mut idle = 0u64;
        for (index, field) in fields.iter().skip(1).take(8).enumerate() {
            let value = parse_u64(field);
            total = total.saturating_add(value);
            if index == 3 || index == 4 {
                idle = idle.saturating_add(value);
            }
        }
        return (total, idle);
    }
    (0, 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_aggregate_cpu_times() {
        let content = "\
cpu  100 20 30 500 40 5 6 7 8 9
cpu0 1 2 3 4
";
        let (total, idle) = parse_cpu_times(content);
        assert_eq!(total, 100 + 20 + 30 + 500 + 40 + 5 + 6 + 7);
        assert_eq!(idle, 500 + 40);
    }

    #[test]
    fn missing_cpu_line_returns_zero() {
        assert_eq!(parse_cpu_times("intr 1 2 3\n"), (0, 0));
    }

    #[test]
    fn sampler_reports_zero_until_primed() {
        let directory = tempfile::tempdir().expect("tempdir");
        let path = directory.path().join("stat");
        std::fs::write(&path, "cpu  100 0 100 800 0 0 0 0\n").unwrap();

        let sampler = CpuSampler::new(&path);
        assert_eq!(sampler.usage_percent(), 0.0);
        assert_eq!(sampler.usage_percent(), 0.0);

        // 100 more busy ticks and 800 more idle ticks -> 20% busy.
        std::fs::write(&path, "cpu  200 0 200 1600 0 0 0 0\n").unwrap();
        assert_eq!(sampler.usage_percent(), 20.0);
    }

    #[test]
    fn sampler_clamps_to_the_valid_range() {
        let directory = tempfile::tempdir().expect("tempdir");
        let path = directory.path().join("stat");
        std::fs::write(&path, "cpu  100 0 0 100 0 0 0 0\n").unwrap();
        let sampler = CpuSampler::new(&path);
        sampler.prime();

        std::fs::write(&path, "cpu  0 0 0 0 0 0 0 0\n").unwrap();
        assert_eq!(sampler.usage_percent(), 0.0);
    }
}
