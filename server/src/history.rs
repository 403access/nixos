use std::collections::VecDeque;
use std::sync::Mutex;

use chrono::{SecondsFormat, Utc};
use serde::{Deserialize, Serialize};

use crate::models::{Status, StatusSample};

pub const DEFAULT_HISTORY_CAPACITY: usize = 2160;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StatusHistoryResponse {
    pub samples: Vec<StatusSample>,
}

/// Bounded in-memory history of host status samples. The server samples every
/// few seconds; the dashboard charts read from here.
pub struct StatusHistory {
    samples: Mutex<VecDeque<StatusSample>>,
    capacity: usize,
}

impl StatusHistory {
    pub fn new(capacity: usize) -> Self {
        Self {
            samples: Mutex::new(VecDeque::with_capacity(capacity.min(256))),
            capacity,
        }
    }

    pub fn record(&self, status: &Status) -> Option<StatusSample> {
        if self.capacity == 0 {
            return None;
        }
        let sample = StatusSample {
            at: Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
            cpu: status.cpu.clone(),
            load: status.load.clone(),
            memory: status.memory.clone(),
            root_disk: status.root_disk.clone(),
            services: status.services.clone(),
            generation: status.generation,
            uptime_seconds: status.uptime_seconds,
            temperatures: status.temperatures.clone(),
            pools: status.pools.clone(),
        };

        let mut samples = self.samples.lock().expect("status history poisoned");
        samples.push_back(sample.clone());
        while samples.len() > self.capacity {
            samples.pop_front();
        }
        Some(sample)
    }

    /// Newest samples within the requested window, oldest first.
    pub fn samples(&self, minutes: i64, limit: usize) -> Vec<StatusSample> {
        let cutoff = (Utc::now() - chrono::Duration::minutes(minutes.max(1)))
            .to_rfc3339_opts(SecondsFormat::Secs, true);
        let samples = self.samples.lock().expect("status history poisoned");
        let mut values: Vec<StatusSample> = samples
            .iter()
            .filter(|sample| sample.at >= cutoff)
            .cloned()
            .collect();
        if values.len() > limit {
            values.drain(0..values.len() - limit);
        }
        values
    }

    pub fn len(&self) -> usize {
        self.samples.lock().expect("status history poisoned").len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{CpuInfo, Status};

    fn status(cpu: f64) -> Status {
        Status {
            cpu: CpuInfo {
                model: "Test CPU".to_string(),
                cores: 4,
                usage_percent: cpu,
            },
            load: vec![0.5, 0.4, 0.3],
            uptime_seconds: 120,
            generation: 7,
            ..Status::default()
        }
    }

    #[test]
    fn records_and_filters_samples() {
        let history = StatusHistory::new(10);
        history.record(&status(12.5));
        history.record(&status(25.0));

        let samples = history.samples(60, 100);
        assert_eq!(samples.len(), 2);
        assert_eq!(samples[1].cpu.usage_percent, 25.0);
        assert!(samples[0].at <= samples[1].at);
        assert_eq!(samples[0].generation, 7);
    }

    #[test]
    fn capacity_drops_the_oldest_sample() {
        let history = StatusHistory::new(2);
        history.record(&status(1.0));
        history.record(&status(2.0));
        history.record(&status(3.0));
        assert_eq!(history.len(), 2);
        let samples = history.samples(60, 100);
        assert_eq!(samples[0].cpu.usage_percent, 2.0);
        assert_eq!(samples[1].cpu.usage_percent, 3.0);
    }

    #[test]
    fn zero_capacity_records_nothing() {
        let history = StatusHistory::new(0);
        assert!(history.record(&status(1.0)).is_none());
        assert!(history.is_empty());
    }
}
