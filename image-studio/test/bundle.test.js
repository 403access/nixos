import test from 'node:test';
import assert from 'node:assert/strict';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { loadConfig } from '../src/config.js';
import { Runner } from '../src/runner.js';
import { exportBundle, importBundle, inspectBundle, listBundles } from '../src/bundle.js';
import { validateNixosProfile } from '../src/profiles.js';
import { ensureDir, sha256File } from '../src/util.js';

async function fixture() {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'image-studio-test-'));
  const config = loadConfig({
    ...process.env,
    IMAGE_STUDIO_DATA: path.join(dir, 'var'),
    IMAGE_STUDIO_HOST: '',
    IMAGE_STUDIO_DRY_RUN: '0',
  });
  await Promise.all([
    ensureDir(config.bundlesDir),
    ensureDir(config.importsDir),
    ensureDir(config.artifactsDir),
    ensureDir(config.jobsDir),
    ensureDir(config.buildsDir),
    ensureDir(config.uploadsDir),
  ]);
  const runner = new Runner(config);
  return { dir, config, runner };
}

test('export, inspect and import a bundle with checksum verification', async () => {
  const { dir, config, runner } = await fixture();
  const artifact = path.join(dir, 'sample.iso');
  await fsp.writeFile(artifact, 'fake iso payload\n');
  const profile = validateNixosProfile({ name: 'bundle-test', hostName: 'bundle-test' });
  const exported = await exportBundle({
    config,
    runner,
    kind: 'nixos',
    profile,
    artifacts: [{ name: 'sample.iso', path: artifact }],
    name: 'bundle-test',
    notes: 'unit test',
  });
  assert.ok(exported.path.endsWith('bundle-test.tar.gz'));
  assert.equal(await sha256File(exported.path).then((hash) => hash.length), 64);

  const inspected = await inspectBundle({ config, runner, file: exported.path });
  assert.equal(inspected.manifest.kind, 'nixos');
  assert.equal(inspected.manifest.artifacts.length, 1);
  assert.equal(inspected.manifest.artifacts[0].sha256, await sha256File(artifact));

  const imported = await importBundle({ config, runner, file: exported.path });
  assert.equal(imported.manifest.id, exported.id);
  assert.equal(imported.artifacts.length, 1);
  assert.ok(await fsp.stat(imported.artifacts[0].path));

  const bundles = await listBundles({ config });
  assert.ok(bundles.some((bundle) => bundle.id === exported.id && bundle.type === 'exported'));
  assert.ok(bundles.some((bundle) => bundle.id === exported.id && bundle.type === 'imported'));
});

test('rejects a bundle whose manifest id escapes the import directory', async () => {
  const { dir, config, runner } = await fixture();
  const source = path.join(dir, 'bad');
  await ensureDir(source);
  await fsp.writeFile(path.join(source, 'manifest.json'), JSON.stringify({
    schema: 'image-studio.bundle/v1',
    id: '../../escape',
    kind: 'nixos',
    profile: validateNixosProfile({}),
    artifacts: [],
  }));
  const archive = path.join(dir, 'bad.tar.gz');
  const packed = await runner.execFile('tar', ['-czf', archive, '-C', source, '.']);
  assert.ok(packed.ok);
  await assert.rejects(() => inspectBundle({ config, runner, file: archive }), /bundle id/);
});

test('rejects an archive without a manifest', async () => {
  const { dir, config, runner } = await fixture();
  const source = path.join(dir, 'empty');
  await ensureDir(source);
  await fsp.writeFile(path.join(source, 'notes.txt'), 'no manifest');
  const archive = path.join(dir, 'empty.tar.gz');
  const packed = await runner.execFile('tar', ['-czf', archive, '-C', source, '.']);
  assert.ok(packed.ok);
  await assert.rejects(() => inspectBundle({ config, runner, file: archive }), /manifest/);
});