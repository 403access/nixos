import { spawn } from 'node:child_process';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { commandLine, redactCommand } from './runner.js';
import { createId, ensureDir, nowIso, readJson, tailFile, writeJson } from './util.js';

const TAIL_LIMIT = 64 * 1024;

export class JobManager {
  constructor(config, { spawnImpl = spawn } = {}) {
    this.config = config;
    this.spawnImpl = spawnImpl;
    this.children = new Map();
    this.tails = new Map();
  }

  async init() {
    await Promise.all([
      ensureDir(this.config.jobsDir),
      ensureDir(this.config.artifactsDir),
      ensureDir(this.config.uploadsDir),
      ensureDir(this.config.bundlesDir),
      ensureDir(this.config.importsDir),
      ensureDir(this.config.buildsDir),
    ]);
    await this.recover();
  }

  async recover() {
    let entries = [];
    try {
      entries = await fsp.readdir(this.config.jobsDir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const file = path.join(this.config.jobsDir, entry.name, 'job.json');
      const job = await readJson(file, null);
      if (!job) continue;
      if (job.status === 'running' || job.status === 'queued') {
        job.status = 'failed';
        job.error = 'controller restarted before the job finished';
        job.finishedAt = nowIso();
        await writeJson(file, job);
      }
    }
  }

  jobDir(id) {
    return path.join(this.config.jobsDir, id);
  }

  logPath(id) {
    return path.join(this.jobDir(id), 'job.log');
  }

  async start({ kind, argv, cwd, env, timeoutMs = this.config.timeoutMs, meta = {}, preview = '' }) {
    if (!Array.isArray(argv) || argv.length === 0) throw new Error('argv is required');
    const id = createId(kind);
    const dir = this.jobDir(id);
    await ensureDir(dir);
    const logPath = this.logPath(id);
    const job = {
      id,
      kind,
      status: 'running',
      createdAt: nowIso(),
      startedAt: nowIso(),
      finishedAt: null,
      exitCode: null,
      command: redactCommand(argv),
      preview: preview || redactCommand(argv),
      meta,
      artifacts: [],
      error: null,
    };
    await writeJson(path.join(dir, 'job.json'), job);

    const header = [
      `# image-studio ${kind} job ${id}`,
      `# started ${job.startedAt}`,
      `# command ${job.command}`,
      '',
    ].join('\n');
    await fsp.writeFile(logPath, header);
    this.tails.set(id, header);

    if (this.config.dryRun) {
      const text = `[dry-run] ${commandLine(argv)}\n[dry-run] completed successfully\n`;
      await fsp.appendFile(logPath, text);
      this.tails.set(id, header + text);
      job.status = 'succeeded';
      job.finishedAt = nowIso();
      job.exitCode = 0;
      await writeJson(path.join(dir, 'job.json'), job);
      return this.get(id);
    }

    let child;
    try {
      child = this.spawnImpl(argv[0], argv.slice(1), {
        cwd: cwd || this.config.repoRoot,
        env: { ...process.env, ...env },
        stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch (error) {
      job.status = 'failed';
      job.error = error.message;
      job.finishedAt = nowIso();
      await writeJson(path.join(dir, 'job.json'), job);
      return this.get(id);
    }
    this.children.set(id, child);

    const append = (chunk) => {
      const text = chunk.toString('utf8');
      const current = this.tails.get(id) || '';
      this.tails.set(id, (current + text).slice(-TAIL_LIMIT));
      fs.appendFile(logPath, text, () => {});
    };
    child.stdout?.on('data', append);
    child.stderr?.on('data', append);
    child.on('error', (error) => append(`\n[job error] ${error.message}\n`));

    const timer = setTimeout(() => {
      append(`\n[job] timeout after ${timeoutMs} ms; killing\n`);
      try { child.kill('SIGKILL'); } catch { /* ignore */ }
    }, Math.max(1000, timeoutMs));

    child.on('close', async (code, signal) => {
      clearTimeout(timer);
      this.children.delete(id);
      const current = await this.get(id);
      current.status = code === 0 ? 'succeeded' : 'failed';
      current.exitCode = code;
      current.finishedAt = nowIso();
      if (signal) current.signal = signal;
      if (code !== 0) current.error = `exit code ${code}${signal ? ` (${signal})` : ''}`;
      await fsp.appendFile(logPath, `\n[job] ${current.status} at ${current.finishedAt}${current.error ? `: ${current.error}` : ''}\n`);
      await writeJson(path.join(dir, 'job.json'), current);
    });

    return this.get(id);
  }

  async get(id) {
    const dir = this.jobDir(id);
    const job = await readJson(path.join(dir, 'job.json'), null);
    if (!job) return null;
    job.output = await tailFile(this.logPath(id), TAIL_LIMIT);
    return job;
  }

  async list() {
    let entries = [];
    try {
      entries = await fsp.readdir(this.config.jobsDir, { withFileTypes: true });
    } catch {
      return [];
    }
    const jobs = [];
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const job = await readJson(path.join(this.config.jobsDir, entry.name, 'job.json'), null);
      if (job) {
        delete job.output;
        jobs.push(job);
      }
    }
    return jobs.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  }

  async log(id, { offset = null } = {}) {
    const file = this.logPath(id);
    const text = await tailFile(file, 1024 * 1024);
    if (offset === null || offset === undefined || Number.isNaN(Number(offset))) {
      return { text, next: Buffer.byteLength(text) };
    }
    const start = Math.max(0, Number(offset));
    const buffer = Buffer.from(text);
    const slice = buffer.subarray(start);
    return { text: slice.toString('utf8'), next: buffer.length };
  }

  async cancel(id) {
    const child = this.children.get(id);
    if (child) {
      try { child.kill('SIGTERM'); } catch { /* ignore */ }
      setTimeout(() => {
        try { child.kill('SIGKILL'); } catch { /* ignore */ }
      }, 3000).unref?.();
    }
    const job = await this.get(id);
    if (job && (job.status === 'running' || job.status === 'queued')) {
      job.status = 'cancelled';
      job.finishedAt = nowIso();
      await writeJson(path.join(this.jobDir(id), 'job.json'), job);
    }
    return this.get(id);
  }

  async update(id, patch) {
    const file = path.join(this.jobDir(id), 'job.json');
    const job = await readJson(file, null);
    if (!job) throw new Error(`job not found: ${id}`);
    Object.assign(job, patch);
    await writeJson(file, job);
    return this.get(id);
  }
}