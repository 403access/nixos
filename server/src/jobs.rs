use std::collections::HashMap;
use std::path::PathBuf;
use std::process::{ExitStatus, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{SecondsFormat, Utc};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::Command;
use tokio::sync::oneshot;

use crate::util::{human_duration, strip_ansi};

pub const DEFAULT_JOB_TIMEOUT: Duration = Duration::from_secs(45 * 60);
const JOB_OUTPUT_LIMIT: usize = 64 * 1024;
const JOB_LIST_LIMIT: usize = 20;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Job {
    pub id: String,
    pub kind: String,
    pub status: String,
    pub started_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    pub output: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// Small ring buffer that keeps only the final `max` bytes written to it.
pub struct TailBuffer {
    data: Mutex<Vec<u8>>,
    max: usize,
}

impl TailBuffer {
    pub fn new(max: usize) -> Self {
        Self {
            data: Mutex::new(Vec::new()),
            max,
        }
    }

    pub fn push(&self, bytes: &[u8]) {
        let mut data = self.data.lock().expect("tail buffer poisoned");
        data.extend_from_slice(bytes);
        if data.len() > self.max {
            let excess = data.len() - self.max;
            data.drain(0..excess);
        }
    }

    pub fn string(&self) -> String {
        let data = self.data.lock().expect("tail buffer poisoned");
        strip_ansi(&String::from_utf8_lossy(&data))
    }
}

struct JobRecord {
    job: Job,
    buffer: Arc<TailBuffer>,
    cancel: Option<oneshot::Sender<()>>,
    finished: bool,
}

#[derive(Default)]
struct Inner {
    jobs: HashMap<String, JobRecord>,
    order: Vec<String>,
}

/// Starts and tracks asynchronous rebuild jobs. The manager is cheap to clone
/// and safe to share across request handlers.
#[derive(Clone)]
pub struct JobManager {
    inner: Arc<Mutex<Inner>>,
    timeout: Duration,
}

/// Abstraction used by the HTTP layer so job endpoints can be tested without
/// spawning real processes.
pub trait JobLauncher: Send + Sync {
    fn start(&self, kind: &str, program: &str, args: Vec<String>, dir: Option<PathBuf>) -> Job;
    fn snapshot(&self, id: &str) -> Option<Job>;
    fn cancel(&self, id: &str) -> Option<Job>;
    fn list(&self) -> Vec<Job>;
}

impl Default for JobManager {
    fn default() -> Self {
        Self::new()
    }
}

impl JobManager {
    pub fn new() -> Self {
        Self::with_timeout(DEFAULT_JOB_TIMEOUT)
    }

    pub fn with_timeout(timeout: Duration) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner::default())),
            timeout,
        }
    }

    pub fn start(&self, kind: &str, program: &str, args: Vec<String>, dir: Option<PathBuf>) -> Job {
        let id = random_id();
        let buffer = Arc::new(TailBuffer::new(JOB_OUTPUT_LIMIT));
        let (cancel_tx, cancel_rx) = oneshot::channel();

        let job = Job {
            id: id.clone(),
            kind: kind.to_string(),
            status: "running".to_string(),
            started_at: now_rfc3339(),
            finished_at: None,
            exit_code: None,
            output: String::new(),
            error: None,
        };

        {
            let mut inner = self.inner.lock().expect("job manager poisoned");
            inner.jobs.insert(
                id.clone(),
                JobRecord {
                    job: job.clone(),
                    buffer: buffer.clone(),
                    cancel: Some(cancel_tx),
                    finished: false,
                },
            );
            inner.order.push(id.clone());
        }

        let inner = self.inner.clone();
        let timeout = self.timeout;
        let task_id = id.clone();
        let program = program.to_string();
        tokio::spawn(async move {
            run_job(
                inner, task_id, program, args, dir, buffer, cancel_rx, timeout,
            )
            .await;
        });

        job
    }

    pub fn snapshot(&self, id: &str) -> Option<Job> {
        let inner = self.inner.lock().expect("job manager poisoned");
        inner.jobs.get(id).map(|record| {
            let mut job = record.job.clone();
            job.output = record.buffer.string();
            job
        })
    }

    pub fn cancel(&self, id: &str) -> Option<Job> {
        {
            let mut inner = self.inner.lock().expect("job manager poisoned");
            if let Some(record) = inner.jobs.get_mut(id) {
                if let Some(cancel) = record.cancel.take() {
                    let _ = cancel.send(());
                }
            }
        }
        self.snapshot(id)
    }

    pub fn list(&self) -> Vec<Job> {
        let inner = self.inner.lock().expect("job manager poisoned");
        let mut jobs = Vec::new();
        for id in inner.order.iter().rev() {
            if jobs.len() >= JOB_LIST_LIMIT {
                break;
            }
            if let Some(record) = inner.jobs.get(id) {
                let mut job = record.job.clone();
                job.output = record.buffer.string();
                jobs.push(job);
            }
        }
        jobs
    }
}

impl JobLauncher for JobManager {
    fn start(&self, kind: &str, program: &str, args: Vec<String>, dir: Option<PathBuf>) -> Job {
        JobManager::start(self, kind, program, args, dir)
    }

    fn snapshot(&self, id: &str) -> Option<Job> {
        JobManager::snapshot(self, id)
    }

    fn cancel(&self, id: &str) -> Option<Job> {
        JobManager::cancel(self, id)
    }

    fn list(&self) -> Vec<Job> {
        JobManager::list(self)
    }
}

enum Outcome {
    Exited(std::io::Result<ExitStatus>),
    Cancelled,
    TimedOut,
}

#[allow(clippy::too_many_arguments)]
async fn run_job(
    inner: Arc<Mutex<Inner>>,
    id: String,
    program: String,
    args: Vec<String>,
    dir: Option<PathBuf>,
    buffer: Arc<TailBuffer>,
    mut cancel_rx: oneshot::Receiver<()>,
    timeout: Duration,
) {
    let mut command = Command::new(&program);
    command
        .args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if let Some(dir) = dir {
        command.current_dir(dir);
    }

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            finish(&inner, &id, "failed", Some(error.to_string()), None);
            return;
        }
    };

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let stdout_task = stdout.map(|stream| spawn_reader(stream, buffer.clone()));
    let stderr_task = stderr.map(|stream| spawn_reader(stream, buffer.clone()));

    let deadline = tokio::time::sleep(timeout);
    tokio::pin!(deadline);

    let outcome = tokio::select! {
        result = child.wait() => Outcome::Exited(result),
        _ = &mut cancel_rx => Outcome::Cancelled,
        _ = &mut deadline => Outcome::TimedOut,
    };

    let mut cancelled = false;
    let mut timed_out = false;
    match outcome {
        Outcome::Exited(_) => {}
        Outcome::Cancelled => {
            cancelled = true;
            let _ = child.kill().await;
            let _ = child.wait().await;
        }
        Outcome::TimedOut => {
            timed_out = true;
            let _ = child.kill().await;
            let _ = child.wait().await;
        }
    }

    if let Some(task) = stdout_task {
        let _ = task.await;
    }
    if let Some(task) = stderr_task {
        let _ = task.await;
    }

    if cancelled {
        finish(
            &inner,
            &id,
            "cancelled",
            Some("cancelled".to_string()),
            None,
        );
        return;
    }
    if timed_out {
        finish(
            &inner,
            &id,
            "failed",
            Some(format!("timed out after {}", human_duration(timeout))),
            None,
        );
        return;
    }

    match outcome {
        Outcome::Exited(Ok(status)) if status.success() => {
            finish(&inner, &id, "succeeded", None, Some(0));
        }
        Outcome::Exited(Ok(status)) => {
            let code = status.code().unwrap_or(-1);
            let error = match status.code() {
                Some(code) => format!("exit status {code}"),
                None => "signal: terminated".to_string(),
            };
            finish(&inner, &id, "failed", Some(error), Some(code));
        }
        Outcome::Exited(Err(error)) => {
            finish(&inner, &id, "failed", Some(error.to_string()), None);
        }
        Outcome::Cancelled | Outcome::TimedOut => unreachable!(),
    }
}

fn spawn_reader<R>(mut stream: R, buffer: Arc<TailBuffer>) -> tokio::task::JoinHandle<()>
where
    R: AsyncRead + Unpin + Send + 'static,
{
    tokio::spawn(async move {
        let mut chunk = [0u8; 8192];
        loop {
            match stream.read(&mut chunk).await {
                Ok(0) | Err(_) => break,
                Ok(read) => buffer.push(&chunk[..read]),
            }
        }
    })
}

fn finish(
    inner: &Arc<Mutex<Inner>>,
    id: &str,
    status: &str,
    error: Option<String>,
    exit_code: Option<i32>,
) {
    let mut inner = inner.lock().expect("job manager poisoned");
    let Some(record) = inner.jobs.get_mut(id) else {
        return;
    };
    if record.finished {
        return;
    }
    record.finished = true;
    record.cancel = None;
    record.job.status = status.to_string();
    record.job.finished_at = Some(now_rfc3339());
    record.job.error = error;
    record.job.exit_code = exit_code;
}

fn now_rfc3339() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn random_id() -> String {
    let mut bytes = [0u8; 8];
    rand::thread_rng().fill_bytes(&mut bytes);
    let mut id = String::with_capacity(16);
    for byte in bytes {
        id.push_str(&format!("{byte:02x}"));
    }
    id
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sh(script: &str) -> (Vec<String>, Option<PathBuf>) {
        (vec!["-c".to_string(), script.to_string()], None)
    }

    async fn wait_for_status(jobs: &JobManager, id: &str, expected: &str) -> Job {
        for _ in 0..200 {
            let job = jobs.snapshot(id).expect("job exists");
            if job.status == expected {
                return job;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("job {id} did not reach {expected}: {:?}", jobs.snapshot(id));
    }

    #[test]
    fn tail_buffer_keeps_only_the_tail() {
        let buffer = TailBuffer::new(5);
        buffer.push(b"abc");
        buffer.push(b"defg");
        assert_eq!(buffer.string(), "cdefg");
    }

    #[test]
    fn tail_buffer_strips_ansi_escapes() {
        let buffer = TailBuffer::new(128);
        buffer.push(b"\x1b[31mred\x1b[0m");
        assert_eq!(buffer.string(), "red");
    }

    #[tokio::test]
    async fn successful_job_captures_output() {
        let jobs = JobManager::new();
        let (args, dir) = sh("printf 'hello'");
        let job = jobs.start("test", "sh", args, dir);

        let finished = wait_for_status(&jobs, &job.id, "succeeded").await;
        assert_eq!(finished.output, "hello");
        assert_eq!(finished.exit_code, Some(0));
        assert!(finished.finished_at.is_some());
        assert!(finished.error.is_none());
    }

    #[tokio::test]
    async fn failed_job_records_exit_code_and_stderr() {
        let jobs = JobManager::new();
        let (args, dir) = sh("printf 'bad' >&2; exit 3");
        let job = jobs.start("test", "sh", args, dir);

        let finished = wait_for_status(&jobs, &job.id, "failed").await;
        assert_eq!(finished.output, "bad");
        assert_eq!(finished.exit_code, Some(3));
        assert_eq!(finished.error.as_deref(), Some("exit status 3"));
    }

    #[tokio::test]
    async fn cancel_marks_the_job_cancelled() {
        let jobs = JobManager::new();
        let (args, dir) = sh("exec sleep 5");
        let job = jobs.start("test", "sh", args, dir);

        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(jobs.cancel(&job.id).is_some());

        let finished = wait_for_status(&jobs, &job.id, "cancelled").await;
        assert_eq!(finished.error.as_deref(), Some("cancelled"));
        assert!(finished.exit_code.is_none());
    }

    #[tokio::test]
    async fn timeout_marks_the_job_failed() {
        let jobs = JobManager::with_timeout(Duration::from_millis(200));
        let (args, dir) = sh("exec sleep 5");
        let job = jobs.start("test", "sh", args, dir);

        let finished = wait_for_status(&jobs, &job.id, "failed").await;
        assert_eq!(
            finished.error.as_deref(),
            Some("timed out after 200 milliseconds")
        );
    }

    #[tokio::test]
    async fn missing_program_fails_immediately() {
        let jobs = JobManager::new();
        let job = jobs.start(
            "test",
            "definitely-not-a-real-command-xyz",
            Vec::new(),
            None,
        );
        let finished = wait_for_status(&jobs, &job.id, "failed").await;
        assert!(finished.error.is_some());
    }

    #[tokio::test]
    async fn list_returns_most_recent_jobs_first() {
        let jobs = JobManager::new();
        let mut ids = Vec::new();
        for value in ["one", "two", "three"] {
            let (args, dir) = sh(&format!("printf {value}"));
            ids.push(jobs.start("test", "sh", args, dir).id);
        }
        for id in &ids {
            wait_for_status(&jobs, id, "succeeded").await;
        }

        let listed = jobs.list();
        assert_eq!(listed.len(), 3);
        assert_eq!(listed[0].id, ids[2]);
        assert_eq!(listed[2].id, ids[0]);
    }

    #[tokio::test]
    async fn unknown_job_lookups_return_none() {
        let jobs = JobManager::new();
        assert!(jobs.snapshot("missing").is_none());
        assert!(jobs.cancel("missing").is_none());
    }
}
