import fsp from 'node:fs/promises';
import fs from 'node:fs';
import path from 'node:path';
import { createId, ensureDir, humanBytes, safeName, shQuote } from './util.js';
import { validateNixosProfile, validateWindowsProfile, renderNixosConfiguration, renderWindowsBuildArgs } from './profiles.js';

async function mkdirHost(config, runner, dir) {
  if (config.host) return runner.runHost(['mkdir', '-p', dir], { timeoutMs: 60_000 });
  await ensureDir(dir);
  return { ok: true };
}

async function writeHostText(config, runner, file, text) {
  if (config.host) return runner.hostWriteFile(file, text, { privileged: false });
  await ensureDir(path.dirname(file));
  await fsp.writeFile(file, text);
  return { ok: true };
}

async function prepareSourceIso(config, runner, sourceIso) {
  const iso = String(sourceIso || '').trim();
  if (!iso) throw new Error('sourceIso is required (upload an ISO or pass a path on the build host)');
  if (config.host) {
    if (await runner.hostExists(iso)) return iso;
    if (fs.existsSync(iso)) {
      const remote = path.posix.join('/tmp/image-studio/uploads', safeName(path.basename(iso), 'ISO file name'));
      await mkdirHost(config, runner, path.posix.dirname(remote));
      const uploaded = await runner.upload(iso, remote);
      if (!uploaded.ok) throw new Error(`ISO upload failed: ${uploaded.output.trim() || uploaded.error}`);
      return remote;
    }
    throw new Error(`source ISO is not present on the build host: ${iso}`);
  }
  if (!fs.existsSync(iso)) throw new Error(`source ISO not found: ${iso}`);
  return iso;
}

export async function planNixosBuild(config, runner, input) {
  const profile = validateNixosProfile(input);
  const id = createId('nixos');
  const localDir = path.join(config.buildsDir, id);
  await ensureDir(localDir);
  const repoRoot = config.host ? config.nixosRepo : config.repoRoot;
  const text = renderNixosConfiguration(profile, { repoRoot });
  const localConfig = path.join(localDir, 'configuration.nix');
  await fsp.writeFile(localConfig, text);

  let buildDir = localDir;
  let configPath = localConfig;
  let outLink = path.join(localDir, 'result');
  if (config.host) {
    buildDir = path.posix.join('/tmp/image-studio/builds', id);
    configPath = path.posix.join(buildDir, 'configuration.nix');
    outLink = path.posix.join(buildDir, 'result');
    await mkdirHost(config, runner, buildDir);
    const write = await writeHostText(config, runner, configPath, text);
    if (!write.ok) throw new Error(`cannot write generated config: ${write.output.trim() || write.error}`);
  }

  const argv = [
    'nix-build', '<nixpkgs/nixos>',
    '-A', 'config.system.build.isoImage',
    '-I', `nixos-config=${configPath}`,
    '--out-link', outLink,
  ];
  return {
    id,
    kind: 'nixos',
    profile,
    buildDir,
    localBuildDir: localDir,
    remote: Boolean(config.host),
    configPath,
    outLink,
    artifactGlob: path.posix.join(outLink, 'iso', '*.iso'),
    argv: runner.wrapHost(argv),
    rawArgv: argv,
    preview: `nix-build '<nixpkgs/nixos>' -A config.system.build.isoImage -I nixos-config=${configPath} --out-link ${outLink}`,
    meta: {
      profile,
      configPath,
      outLink,
      remote: Boolean(config.host),
      id,
      kind: 'nixos',
    },
  };
}

export async function planWindowsBuild(config, runner, input) {
  const profile = validateWindowsProfile(input);
  const sourceIso = await prepareSourceIso(config, runner, input.sourceIso || profile.sourceIso);
  const id = createId('windows');
  const localDir = path.join(config.buildsDir, id);
  await ensureDir(localDir);
  const repo = config.host ? config.nixosRepo : config.repoRoot;
  const remoteDir = path.posix.join('/tmp/image-studio/builds', id);
  const outputPath = config.host ? path.posix.join(remoteDir, profile.outputName) : path.join(localDir, profile.outputName);
  const workDir = config.host ? path.posix.join(remoteDir, 'work') : path.join(localDir, 'work');

  if (config.host) {
    await mkdirHost(config, runner, remoteDir);
    await mkdirHost(config, runner, workDir);
  } else {
    await ensureDir(workDir);
  }

  const scriptArgs = renderWindowsBuildArgs(profile, {
    repoRoot: repo,
    sourceIso,
    outputPath,
    workDir,
    docker: config.docker,
    force: true,
  });
  const argv = ['bash', ...scriptArgs];
  return {
    id,
    kind: 'windows',
    profile,
    buildDir: config.host ? remoteDir : localDir,
    localBuildDir: localDir,
    remote: Boolean(config.host),
    sourceIso,
    artifactPath: outputPath,
    argv: runner.wrapHost(argv),
    rawArgv: argv,
    preview: scriptArgs.join(' '),
    meta: {
      profile,
      sourceIso,
      artifactPath: outputPath,
      remote: Boolean(config.host),
      id,
      kind: 'windows',
    },
  };
}

async function walkFiles(dir, predicate) {
  const out = [];
  async function walk(current) {
    let entries = [];
    try { entries = await fsp.readdir(current, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) await walk(full);
      else if (predicate(entry.name)) {
        const stat = await fsp.stat(full);
        out.push({ name: entry.name, path: full, size: stat.size, remote: false });
      }
    }
  }
  await walk(dir);
  return out;
}

export async function discoverArtifacts(config, runner, plan) {
  if (plan.artifactPath) {
    if (plan.remote) {
      const stat = await runner.runHostShell(`stat -c '%s' ${shQuote(plan.artifactPath)}`, { timeoutMs: 30_000 });
      if (!stat.ok) return [];
      return [{ name: path.posix.basename(plan.artifactPath), path: plan.artifactPath, size: Number(stat.stdout.trim()) || 0, remote: true }];
    }
    try {
      const stat = await fsp.stat(plan.artifactPath);
      return [{ name: path.basename(plan.artifactPath), path: plan.artifactPath, size: stat.size, remote: false }];
    } catch {
      return [];
    }
  }
  if (plan.artifactGlob) {
    const dir = path.posix.dirname(plan.artifactGlob);
    if (plan.remote) {
      const result = await runner.runHostShell(`find ${shQuote(dir)} -maxdepth 1 -type f -name '*.iso' -printf '%f\\t%s\\n'`, { timeoutMs: 60_000 });
      if (!result.ok) return [];
      return result.stdout.split(/\r?\n/).filter(Boolean).map((line) => {
        const [name, size] = line.split('\t');
        return { name, path: path.posix.join(dir, name), size: Number(size) || 0, remote: true };
      });
    }
    return walkFiles(dir, (name) => name.toLowerCase().endsWith('.iso'));
  }
  return [];
}

export async function materializeArtifact(config, runner, artifact, target) {
  await ensureDir(path.dirname(target));
  if (artifact.remote) {
    const result = await runner.download(artifact.path, target);
    if (!result.ok) throw new Error(`download failed: ${result.output.trim() || result.error}`);
  } else {
    await fsp.copyFile(artifact.path, target);
  }
  const stat = await fsp.stat(target);
  return { ...artifact, localPath: target, size: stat.size, sizeHuman: humanBytes(stat.size) };
}

export function artifactSummary(artifacts) {
  return artifacts.map((artifact) => ({
    name: artifact.name,
    size: artifact.size,
    sizeHuman: humanBytes(artifact.size),
    remote: artifact.remote,
  }));
}

/** Reconstruct the artifact discovery plan from a job's persisted metadata. */
export function planFromJob(job) {
  const meta = job.meta || {};
  if (job.kind === 'nixos') {
    if (!meta.outLink) throw new Error('job has no NixOS output link');
    return {
      remote: Boolean(meta.remote),
      artifactGlob: path.posix.join(meta.outLink, 'iso', '*.iso'),
    };
  }
  if (job.kind === 'windows') {
    if (!meta.artifactPath) throw new Error('job has no Windows artifact path');
    return { remote: Boolean(meta.remote), artifactPath: meta.artifactPath };
  }
  throw new Error(`unsupported job kind: ${job.kind}`);
}