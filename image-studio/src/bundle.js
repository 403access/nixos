import fsp from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { createId, ensureDir, nowIso, readJson, safeName, sha256File, writeJson } from './util.js';
import { validateProfile } from './profiles.js';
import { discoverArtifacts, materializeArtifact } from './images.js';

export const BUNDLE_SCHEMA = 'image-studio.bundle/v1';

function manifestPath(dir) {
  return path.join(dir, 'manifest.json');
}

function validateBundleName(name) {
  const value = safeName(String(name || ''), 'bundle name');
  return value.toLowerCase().endsWith('.tar.gz') ? value : `${value}.tar.gz`;
}

async function tarList(runner, file) {
  const result = await runner.execFile('tar', ['-tzf', file], { timeoutMs: 120_000 });
  if (!result.ok) throw new Error(`cannot read bundle: ${result.output.trim() || result.error}`);
  return result.stdout.split(/\r?\n/).filter(Boolean);
}

async function tarVerbose(runner, file) {
  const result = await runner.execFile('tar', ['-tvzf', file], { timeoutMs: 120_000 });
  if (!result.ok) throw new Error(`cannot inspect bundle: ${result.output.trim() || result.error}`);
  return result.stdout.split(/\r?\n/).filter(Boolean);
}

function validateEntries(names, verbose) {
  if (names.length > 10_000) throw new Error('bundle contains too many entries');
  if (names.length !== verbose.length) throw new Error('bundle listing is inconsistent');
  for (let i = 0; i < names.length; i += 1) {
    const type = verbose[i][0];
    if (!['-', 'd'].includes(type)) throw new Error(`bundle contains unsupported entry type: ${type}`);
    const name = names[i];
    if (!name) continue;
    if (name.startsWith('/') || name.includes('\0')) throw new Error(`unsafe bundle path: ${name}`);
    const parts = name.replace(/\\/g, '/').split('/');
    if (parts.includes('..')) throw new Error(`bundle path traversal: ${name}`);
  }
}

function validateManifest(manifest) {
  if (!manifest || manifest.schema !== BUNDLE_SCHEMA) throw new Error(`unsupported bundle schema (expected ${BUNDLE_SCHEMA})`);
  if (!['nixos', 'windows'].includes(manifest.kind)) throw new Error('bundle kind must be nixos or windows');
  safeName(manifest.id, 'bundle id');
  validateProfile(manifest.kind, manifest.profile);
  if (!Array.isArray(manifest.artifacts)) throw new Error('bundle manifest has no artifacts array');
  for (const artifact of manifest.artifacts) {
    safeName(artifact.name, 'artifact name');
    if (!Number.isFinite(Number(artifact.size))) throw new Error('artifact size is invalid');
    if (!/^[a-f0-9]{64}$/i.test(String(artifact.sha256))) throw new Error('artifact sha256 is invalid');
  }
  return manifest;
}

export async function exportBundle({
  config,
  runner,
  kind,
  profile,
  job = null,
  plan = null,
  artifacts = [],
  notes = '',
  name = '',
} = {}) {
  if (!['nixos', 'windows'].includes(kind)) throw new Error('kind must be nixos or windows');
  const normalized = validateProfile(kind, profile);
  const id = createId('bundle');
  const dir = path.join(config.bundlesDir, id);
  const artifactDir = path.join(dir, 'artifacts');
  await ensureDir(artifactDir);

  let sourceArtifacts = artifacts;
  if (job && plan) {
    sourceArtifacts = await discoverArtifacts(config, runner, plan);
  }
  const manifestArtifacts = [];
  for (const artifact of sourceArtifacts) {
    const artifactName = safeName(artifact.name, 'artifact name');
    const target = path.join(artifactDir, artifactName);
    let local;
    if (artifact.remote) {
      local = await materializeArtifact(config, runner, artifact, target);
    } else {
      await fsp.copyFile(artifact.path, target);
      const stat = await fsp.stat(target);
      local = { ...artifact, localPath: target, size: stat.size };
    }
    manifestArtifacts.push({
      name: artifactName,
      size: local.size,
      sha256: await sha256File(target),
      description: artifact.description || '',
    });
  }

  const outName = validateBundleName(name || `${kind}-${normalized.name}.tar.gz`);
  const outPath = path.join(config.bundlesDir, outName);
  const manifest = validateManifest({
    schema: BUNDLE_SCHEMA,
    id,
    name: name || `${kind}-${id}`,
    createdAt: nowIso(),
    kind,
    profile: normalized,
    artifacts: manifestArtifacts,
    notes: String(notes || ''),
    sourceJob: job?.id || null,
    postInstall: normalized.postInstall || [],
    archive: outName,
  });
  await writeJson(manifestPath(dir), manifest);
  await writeJson(path.join(dir, 'profile.json'), normalized);
  await fsp.writeFile(
    path.join(dir, 'README.txt'),
    [
      `Image Studio ${kind} bundle`,
      `created: ${manifest.createdAt}`,
      `profile: ${normalized.name}`,
      '',
      'Import with: image-studio (web) -> Import bundle',
      'The JSON profile can be reused to rebuild the image.',
      '',
    ].join('\n'),
  );

  const result = await runner.execFile('tar', ['-czf', outPath, '-C', dir, '.'], { timeoutMs: 60 * 60 * 1000 });
  if (!result.ok) throw new Error(`bundle packaging failed: ${result.output.trim() || result.error}`);
  const stat = await fsp.stat(outPath);
  return { id, path: outPath, name: outName, size: stat.size, manifest };
}

export async function inspectBundle({ config, runner, file }) {
  const entries = await tarList(runner, file);
  if (!entries.includes('manifest.json') && !entries.includes('./manifest.json')) {
    throw new Error('bundle has no manifest.json');
  }
  validateEntries(entries, await tarVerbose(runner, file));
  const temp = path.join(config.importsDir, `.inspect-${createId('bundle')}`);
  await ensureDir(temp);
  try {
    const extract = await runner.execFile('tar', ['-xzf', file, '-C', temp, '--no-same-owner'], { timeoutMs: 60 * 60 * 1000 });
    if (!extract.ok) throw new Error(`bundle extraction failed: ${extract.output.trim() || extract.error}`);
    const manifest = await readJson(path.join(temp, 'manifest.json'), null);
    return { manifest: validateManifest(manifest), entries };
  } finally {
    await fsp.rm(temp, { recursive: true, force: true });
  }
}

export async function importBundle({ config, runner, file }) {
  const inspected = await inspectBundle({ config, runner, file });
  const manifest = inspected.manifest;
  const dir = path.join(config.importsDir, manifest.id);
  await fsp.rm(dir, { recursive: true, force: true });
  await ensureDir(dir);
  const extract = await runner.execFile('tar', ['-xzf', file, '-C', dir, '--no-same-owner'], { timeoutMs: 60 * 60 * 1000 });
  if (!extract.ok) throw new Error(`bundle extraction failed: ${extract.output.trim() || extract.error}`);
  const artifacts = [];
  for (const artifact of manifest.artifacts) {
    const artifactPath = path.join(dir, 'artifacts', artifact.name);
    const actual = await sha256File(artifactPath).catch(() => null);
    if (actual !== artifact.sha256) throw new Error(`artifact hash mismatch: ${artifact.name}`);
    artifacts.push({ ...artifact, path: artifactPath });
  }
  await writeJson(path.join(dir, 'import.json'), {
    importedAt: nowIso(),
    sourceFile: path.basename(file),
    manifest,
  });
  return { id: manifest.id, dir, manifest, artifacts };
}

export async function listBundles({ config }) {
  const out = [];
  for (const [root, type] of [
    [config.bundlesDir, 'exported'],
    [config.importsDir, 'imported'],
  ]) {
    let entries = [];
    try { entries = await fsp.readdir(root, { withFileTypes: true }); } catch { continue; }
    for (const entry of entries) {
      if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
      const manifest = await readJson(path.join(root, entry.name, 'manifest.json'), null);
      if (manifest) out.push({ id: entry.name, type, manifest, dir: path.join(root, entry.name) });
    }
  }
  return out.sort((a, b) => String(b.manifest.createdAt).localeCompare(String(a.manifest.createdAt)));
}

export async function getBundle({ config, id }) {
  const clean = safeName(id, 'bundle id');
  for (const [root, type] of [
    [config.bundlesDir, 'exported'],
    [config.importsDir, 'imported'],
  ]) {
    const dir = path.join(root, clean);
    const manifest = await readJson(path.join(dir, 'manifest.json'), null);
    if (manifest) return { id: clean, type, dir, manifest };
  }
  return null;
}

export function sha256Text(text) {
  return createHash('sha256').update(text).digest('hex');
}