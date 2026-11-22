import test from 'node:test';
import assert from 'node:assert/strict';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { loadConfig } from '../src/config.js';
import { Runner } from '../src/runner.js';
import { JobManager } from '../src/jobs.js';
import { OfflineImage } from '../src/offline.js';
import { LiveSystem } from '../src/live.js';
import { createWebServer } from '../src/web.js';
import { ensureDir } from '../src/util.js';

async function startApp({ token = '' } = {}) {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'image-studio-web-'));
  const config = loadConfig({
    ...process.env,
    IMAGE_STUDIO_DATA: path.join(dir, 'var'),
    IMAGE_STUDIO_HOST: '',
    IMAGE_STUDIO_DRY_RUN: '1',
    IMAGE_STUDIO_TOKEN: token,
    IMAGE_STUDIO_PORT: '0',
  });
  await Promise.all([
    ensureDir(config.uploadsDir),
    ensureDir(config.buildsDir),
    ensureDir(config.artifactsDir),
    ensureDir(config.bundlesDir),
    ensureDir(config.importsDir),
    ensureDir(config.jobsDir),
  ]);
  const runner = new Runner(config);
  const jobs = new JobManager(config);
  await jobs.init();
  const server = createWebServer({
    config,
    runner,
    jobs,
    offline: new OfflineImage(config, runner),
    live: new LiveSystem(config, runner),
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  return { dir, config, server, base, jobs, runner };
}

async function json(url, options) {
  const response = await fetch(url, options);
  const body = await response.json();
  return { response, body };
}

test('web health and profile endpoints', async (t) => {
  const app = await startApp();
  t.after(() => app.server.close());
  const health = await json(`${app.base}/api/health`);
  assert.equal(health.response.status, 200);
  assert.equal(health.body.mode, 'local');
  assert.equal(health.body.dryRun, true);

  const profiles = await json(`${app.base}/api/profiles`);
  assert.equal(profiles.response.status, 200);
  assert.ok(profiles.body.nixos.length >= 1);
  assert.ok(profiles.body.windows.length >= 1);
});

test('build a NixOS job, export and import the bundle', async (t) => {
  const app = await startApp();
  t.after(() => app.server.close());

  const build = await json(`${app.base}/api/builds`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      kind: 'nixos',
      profile: { name: 'web-nixos', hostName: 'web-nixos', packages: ['git'] },
    }),
  });
  assert.equal(build.response.status, 201);
  assert.equal(build.body.job.status, 'succeeded');
  const jobId = build.body.job.id;

  const job = await json(`${app.base}/api/builds/${jobId}`);
  assert.equal(job.body.job.kind, 'nixos');
  assert.ok(Array.isArray(job.body.artifacts));

  const exported = await json(`${app.base}/api/export`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jobId, name: 'web-bundle.tar.gz', notes: 'web test' }),
  });
  assert.equal(exported.response.status, 201);
  assert.ok(exported.body.downloadUrl);
  const bundlePath = path.join(app.config.bundlesDir, exported.body.name);
  const archive = await fsp.readFile(bundlePath);

  const importedResponse = await fetch(`${app.base}/api/import`, {
    method: 'POST',
    headers: { 'content-type': 'application/gzip', 'x-filename': 'web-bundle.tar.gz' },
    body: archive,
  });
  assert.equal(importedResponse.status, 201);
  const imported = await importedResponse.json();
  assert.equal(imported.manifest.kind, 'nixos');

  const bundles = await json(`${app.base}/api/bundles`);
  assert.ok(bundles.body.bundles.some((bundle) => bundle.id === exported.body.id));
});

test('build a Windows job in dry-run mode', async (t) => {
  const app = await startApp();
  t.after(() => app.server.close());
  const iso = path.join(app.dir, 'Win11.iso');
  await fsp.writeFile(iso, 'fake iso');
  const build = await json(`${app.base}/api/builds`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      kind: 'windows',
      sourceIso: iso,
      profile: {
        name: 'web-win',
        profile: 'lean',
        sourceIso: iso,
        userName: 'Windows-PC',
        computerName: 'WIN-TEST',
        outputName: 'Win11-web.iso',
      },
    }),
  });
  assert.equal(build.response.status, 201);
  assert.equal(build.body.job.kind, 'windows');
  assert.equal(build.body.job.status, 'succeeded');
});

test('token protection', async (t) => {
  const app = await startApp({ token: 'secret-token' });
  t.after(() => app.server.close());
  const index = await fetch(`${app.base}/`);
  assert.equal(index.status, 200);
  const denied = await fetch(`${app.base}/api/health`);
  assert.equal(denied.status, 401);
  const allowed = await fetch(`${app.base}/api/health`, {
    headers: { authorization: 'Bearer secret-token' },
  });
  assert.equal(allowed.status, 200);
});