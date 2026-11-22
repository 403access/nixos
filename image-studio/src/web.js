import fs from 'node:fs';
import fsp from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { createHash, timingSafeEqual } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { loadConfig } from './config.js';
import { LiveSystem } from './live.js';
import { JobManager } from './jobs.js';
import { OfflineImage } from './offline.js';
import { Runner } from './runner.js';
import {
  discoverArtifacts,
  planFromJob,
  planNixosBuild,
  planWindowsBuild,
} from './images.js';
import { exportBundle, getBundle, importBundle, listBundles } from './bundle.js';
import { profilePresets, validateProfile } from './profiles.js';
import { createId, requireConfirm, safeJoin, safeName, shQuote } from './util.js';

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.iso': 'application/octet-stream',
  '.gz': 'application/gzip',
};

function sendJson(res, status, value) {
  const body = JSON.stringify(value, null, 2);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body),
  });
  res.end(body);
}

function sendText(res, status, text, type = 'text/plain; charset=utf-8') {
  res.writeHead(status, { 'content-type': type, 'cache-control': 'no-store' });
  res.end(text);
}

function authorized(config, req, url) {
  if (!config.token) return true;
  const header = String(req.headers.authorization || '');
  const supplied = header.startsWith('Bearer ') ? header.slice(7) : url.searchParams.get('token');
  if (!supplied) return false;
  const a = Buffer.from(String(supplied));
  const b = Buffer.from(config.token);
  return a.length === b.length && timingSafeEqual(a, b);
}

async function readJsonBody(req, limit = 2 * 1024 * 1024) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit) throw new HttpError(413, 'request body is too large');
    chunks.push(chunk);
  }
  if (!size) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new HttpError(400, 'invalid JSON body');
  }
}

async function saveUpload(req, file, maxBytes) {
  await fsp.mkdir(path.dirname(file), { recursive: true });
  const hash = createHash('sha256');
  let size = 0;
  const out = fs.createWriteStream(file);
  try {
    for await (const chunk of req) {
      size += chunk.length;
      if (size > maxBytes) throw new HttpError(413, `upload exceeds ${maxBytes} bytes`);
      hash.update(chunk);
      if (!out.write(chunk)) await new Promise((resolve) => out.once('drain', resolve));
    }
    await new Promise((resolve, reject) => out.end((error) => (error ? reject(error) : resolve())));
  } catch (error) {
    out.destroy();
    await fsp.rm(file, { force: true }).catch(() => {});
    throw error;
  }
  return { size, sha256: hash.digest('hex') };
}

function jobPlan(job) {
  try {
    return planFromJob(job);
  } catch {
    return null;
  }
}

async function jobWithArtifacts(config, runner, jobs, id) {
  const job = await jobs.get(id);
  if (!job) throw new HttpError(404, `job not found: ${id}`);
  let artifacts = [];
  const plan = jobPlan(job);
  if (plan && job.status === 'succeeded') {
    artifacts = await discoverArtifacts(config, runner, plan).catch(() => []);
  }
  return { job, artifacts };
}

function streamRemote(config, runner, remotePath, res) {
  if (!config.host) throw new HttpError(500, 'remote artifact requested without IMAGE_STUDIO_HOST');
  const child = spawn('ssh', [...runner.sshArgs(config.host), '--', `cat ${shQuote(remotePath)}`], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
  child.on('error', () => res.destroy());
  child.on('close', (code) => {
    if (code !== 0 && !res.writableEnded) {
      res.destroy(new Error(stderr.trim() || `ssh cat exited ${code}`));
    }
  });
  res.on('close', () => { try { child.kill('SIGKILL'); } catch { /* ignore */ } });
  child.stdout.pipe(res);
}

function streamFile(file, res) {
  const stream = fs.createReadStream(file);
  stream.on('error', (error) => res.destroy(error));
  stream.pipe(res);
}

export function createWebServer({ config, runner, jobs, offline, live }) {
  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
      const pathname = decodeURIComponent(url.pathname);
      const isStatic = req.method === 'GET' && ['/', '/index.html', '/app.js', '/style.css'].includes(pathname);
      if (!isStatic && !authorized(config, req, url)) {
        sendJson(res, 401, { error: 'unauthorized' });
        return;
      }

      if (req.method === 'GET' && (pathname === '/' || pathname === '/index.html')) {
        const body = await fsp.readFile(path.join(config.publicDir, 'index.html'));
        res.writeHead(200, { 'content-type': MIME['.html'], 'cache-control': 'no-store' });
        res.end(body);
        return;
      }
      if (req.method === 'GET' && (pathname === '/app.js' || pathname === '/style.css')) {
        const name = pathname.slice(1);
        const body = await fsp.readFile(safeJoin(config.publicDir, name));
        res.writeHead(200, { 'content-type': MIME[path.extname(name)] || 'application/octet-stream', 'cache-control': 'no-store' });
        res.end(body);
        return;
      }

      if (pathname === '/api/health' && req.method === 'GET') {
        const capabilities = await runner.capabilities();
        sendJson(res, 200, {
          ok: true,
          version: config.version,
          mode: config.host ? 'ssh' : 'local',
          dryRun: config.dryRun,
          domain: config.domain,
          dataDir: config.dataDir,
          capabilities,
        });
        return;
      }

      if (pathname === '/api/profiles' && req.method === 'GET') {
        sendJson(res, 200, profilePresets());
        return;
      }

      if (pathname === '/api/validate' && req.method === 'POST') {
        const body = await readJsonBody(req);
        sendJson(res, 200, validateProfile(body.kind, body.profile));
        return;
      }

      if (pathname === '/api/builds' && req.method === 'GET') {
        sendJson(res, 200, { jobs: await jobs.list() });
        return;
      }

      if (pathname === '/api/builds' && req.method === 'POST') {
        const body = await readJsonBody(req);
        const kind = String(body.kind || '');
        if (!body.profile || typeof body.profile !== 'object') throw new HttpError(400, 'profile is required');
        let plan;
        if (kind === 'nixos') {
          plan = await planNixosBuild(config, runner, body.profile);
        } else if (kind === 'windows') {
          const profile = { ...body.profile };
          if (body.sourceIso) profile.sourceIso = body.sourceIso;
          plan = await planWindowsBuild(config, runner, profile);
        } else {
          throw new HttpError(400, 'kind must be nixos or windows');
        }
        const job = await jobs.start({
          kind,
          argv: plan.argv,
          meta: plan.meta,
          preview: plan.preview,
        });
        sendJson(res, 201, {
          job,
          plan: {
            preview: plan.preview,
            buildDir: plan.buildDir,
            sourceIso: plan.sourceIso || null,
          },
        });
        return;
      }

      const jobMatch = pathname.match(/^\/api\/builds\/([^/]+)(?:\/(log|cancel|artifacts\/([^/]+)))?$/);
      if (jobMatch) {
        const [, id, action, artifactName] = jobMatch;
        if (!action && req.method === 'GET') {
          sendJson(res, 200, await jobWithArtifacts(config, runner, jobs, id));
          return;
        }
        if (action === 'log' && req.method === 'GET') {
          const offset = url.searchParams.get('offset');
          sendJson(res, 200, await jobs.log(id, { offset }));
          return;
        }
        if (action === 'cancel' && req.method === 'POST') {
          sendJson(res, 200, { job: await jobs.cancel(id) });
          return;
        }
        if (action === 'artifacts' && artifactName && req.method === 'GET') {
          const { artifacts } = await jobWithArtifacts(config, runner, jobs, id);
          const artifact = artifacts.find((item) => item.name === artifactName);
          if (!artifact) throw new HttpError(404, `artifact not found: ${artifactName}`);
          res.writeHead(200, {
            'content-type': 'application/octet-stream',
            'content-disposition': `attachment; filename="${artifact.name.replace(/"/g, '')}"`,
            ...(artifact.size ? { 'content-length': artifact.size } : {}),
          });
          if (artifact.remote) streamRemote(config, runner, artifact.path, res);
          else streamFile(artifact.path, res);
          return;
        }
      }

      if (pathname === '/api/uploads' && req.method === 'POST') {
        const requested = String(req.headers['x-filename'] || url.searchParams.get('name') || '');
        if (!requested) throw new HttpError(400, 'X-Filename or ?name is required');
        const name = safeName(path.basename(requested), 'upload name');
        const target = path.join(config.uploadsDir, name);
        const saved = await saveUpload(req, target, config.maxUpload);
        sendJson(res, 201, { name, path: target, ...saved });
        return;
      }

      if (pathname === '/api/import' && req.method === 'POST') {
        const name = safeName(path.basename(String(req.headers['x-filename'] || 'bundle.tar.gz')), 'bundle file name');
        if (!name.endsWith('.tar.gz')) throw new HttpError(400, 'bundle must be a .tar.gz file');
        const target = path.join(config.uploadsDir, `import-${createId('bundle')}.tar.gz`);
        const saved = await saveUpload(req, target, config.maxUpload);
        const imported = await importBundle({ config, runner, file: target });
        sendJson(res, 201, { ...imported, upload: saved });
        return;
      }

      if (pathname === '/api/bundles' && req.method === 'GET') {
        sendJson(res, 200, { bundles: await listBundles({ config }) });
        return;
      }

      if (pathname === '/api/export' && req.method === 'POST') {
        const body = await readJsonBody(req);
        const job = await jobs.get(String(body.jobId || ''));
        if (!job) throw new HttpError(404, 'job not found');
        if (job.status !== 'succeeded') throw new HttpError(400, `job is ${job.status}`);
        const plan = planFromJob(job);
        const result = await exportBundle({
          config,
          runner,
          kind: job.kind,
          profile: job.meta.profile,
          job,
          plan,
          name: body.name,
          notes: body.notes,
        });
        sendJson(res, 201, {
          id: result.id,
          name: result.name,
          size: result.size,
          downloadUrl: `/api/bundles/${result.id}/download`,
          manifest: result.manifest,
        });
        return;
      }

      const bundleMatch = pathname.match(/^\/api\/bundles\/([^/]+)(?:\/(download))?$/);
      if (bundleMatch) {
        const [, id, download] = bundleMatch;
        const bundle = await getBundle({ config, id });
        if (!bundle) throw new HttpError(404, 'bundle not found');
        if (!download && req.method === 'GET') {
          sendJson(res, 200, bundle);
          return;
        }
        if (download && req.method === 'GET') {
          let archive = bundle.manifest.archive
            ? path.join(config.bundlesDir, path.basename(bundle.manifest.archive))
            : null;
          if (!archive || !fs.existsSync(archive)) {
            archive = path.join(config.bundlesDir, `.download-${id}.tar.gz`);
            const result = await runner.execFile('tar', ['-czf', archive, '-C', bundle.dir, '.'], { timeoutMs: 60 * 60 * 1000 });
            if (!result.ok) throw new HttpError(500, `cannot package bundle: ${result.output.trim() || result.error}`);
          }
          res.writeHead(200, {
            'content-type': 'application/gzip',
            'content-disposition': `attachment; filename="${path.basename(archive)}"`,
          });
          streamFile(archive, res);
          return;
        }
      }

      throw new HttpError(404, 'not found');
    } catch (error) {
      const status = error instanceof HttpError ? error.status : 500;
      if (!res.headersSent) sendJson(res, status, { error: error.message });
      else res.destroy(error);
    }
  });

  return server;
}

export async function startWebServer({ config = loadConfig() } = {}) {
  const runner = new Runner(config);
  const jobs = new JobManager(config);
  await jobs.init();
  const offline = new OfflineImage(config, runner);
  const live = new LiveSystem(config, runner);
  const server = createWebServer({ config, runner, jobs, offline, live });

  if (!config.token && !['127.0.0.1', '::1', 'localhost'].includes(config.bind)) {
    throw new Error('refusing to bind a non-loopback address without IMAGE_STUDIO_TOKEN');
  }

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(config.port, config.bind, resolve);
  });
  const address = server.address();
  const url = `http://${address.address.includes(':') ? `[${address.address}]` : address.address}:${address.port}`;
  process.stderr.write(`image-studio web: ${url}${config.token ? ' (token required)' : ''}\n`);
  return { server, url, config, runner, jobs, offline, live };
}

function isMain() {
  return process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
}

if (isMain()) {
  startWebServer().catch((error) => {
    process.stderr.write(`image-studio web: ${error.stack || error.message}\n`);
    process.exit(1);
  });
}