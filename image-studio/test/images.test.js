import test from 'node:test';
import assert from 'node:assert/strict';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { loadConfig } from '../src/config.js';
import { Runner } from '../src/runner.js';
import { discoverArtifacts, materializeArtifact, planNixosBuild, planWindowsBuild } from '../src/images.js';
import { ensureDir } from '../src/util.js';

async function fixture() {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'image-studio-images-'));
  const config = loadConfig({
    ...process.env,
    IMAGE_STUDIO_DATA: path.join(dir, 'var'),
    IMAGE_STUDIO_HOST: '',
    IMAGE_STUDIO_DRY_RUN: '1',
  });
  await Promise.all([
    ensureDir(config.buildsDir),
    ensureDir(config.artifactsDir),
    ensureDir(config.bundlesDir),
    ensureDir(config.jobsDir),
    ensureDir(config.uploadsDir),
    ensureDir(config.importsDir),
  ]);
  return { dir, config, runner: new Runner(config) };
}

test('NixOS build plan renders a config and discovers its ISO', async () => {
  const { config, runner } = await fixture();
  const plan = await planNixosBuild(config, runner, { name: 'plan-nixos', hostName: 'plan-nixos' });
  assert.ok(await fsp.stat(plan.configPath));
  assert.equal(plan.argv[0], 'nix-build');
  assert.ok(plan.argv.includes('config.system.build.isoImage'));
  await ensureDir(path.join(plan.outLink, 'iso'));
  const iso = path.join(plan.outLink, 'iso', 'plan.iso');
  await fsp.writeFile(iso, 'iso data');
  const artifacts = await discoverArtifacts(config, runner, plan);
  assert.equal(artifacts.length, 1);
  assert.equal(artifacts[0].name, 'plan.iso');
  const target = path.join(config.artifactsDir, 'copy.iso');
  const copied = await materializeArtifact(config, runner, artifacts[0], target);
  assert.ok(copied.size > 0);
  assert.equal((await fsp.readFile(target, 'utf8')), 'iso data');
});

test('Windows build plan uses the wrapper and exact artifact path', async () => {
  const { dir, config, runner } = await fixture();
  const iso = path.join(dir, 'source.iso');
  await fsp.writeFile(iso, 'source');
  const plan = await planWindowsBuild(config, runner, {
    name: 'plan-win',
    profile: 'lean',
    sourceIso: iso,
    outputName: 'custom.iso',
    autologon: true,
  });
  assert.equal(plan.argv[0], 'bash');
  assert.ok(plan.argv[1].endsWith('/windows/build-win11-docker.sh'));
  assert.ok(plan.argv.includes('--autologon'));
  assert.ok(plan.artifactPath.endsWith('custom.iso'));
  await fsp.writeFile(plan.artifactPath, 'built iso');
  const artifacts = await discoverArtifacts(config, runner, plan);
  assert.equal(artifacts[0].name, 'custom.iso');
  assert.equal(artifacts[0].size, 9);
});