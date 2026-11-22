import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const PKG_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const REPO_ROOT = path.resolve(PKG_ROOT, '..');

function envBool(value, fallback = false) {
  if (value === undefined || value === '') return fallback;
  return /^(1|true|yes|on)$/i.test(String(value));
}

function envInt(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

export function loadConfig(env = process.env) {
  const version = JSON.parse(fs.readFileSync(path.join(PKG_ROOT, 'package.json'), 'utf8')).version;
  const dataDir = path.resolve(env.IMAGE_STUDIO_DATA || path.join(PKG_ROOT, 'var'));
  const host = String(env.IMAGE_STUDIO_HOST || '').trim();
  const winHost = String(env.IMAGE_STUDIO_WIN_HOST || 'Windows-PC@192.168.122.50').trim();
  const domain = String(env.IMAGE_STUDIO_DOMAIN || 'win11-stock').trim();
  let token = String(env.IMAGE_STUDIO_TOKEN || '');
  if (!token && env.IMAGE_STUDIO_TOKEN_FILE) {
    try { token = fs.readFileSync(env.IMAGE_STUDIO_TOKEN_FILE, 'utf8').trim(); } catch { token = ''; }
  }

  return {
    version,
    pkgRoot: PKG_ROOT,
    repoRoot: path.resolve(env.IMAGE_STUDIO_REPO_ROOT || REPO_ROOT),
    dataDir,
    jobsDir: path.join(dataDir, 'jobs'),
    uploadsDir: path.join(dataDir, 'uploads'),
    artifactsDir: path.join(dataDir, 'artifacts'),
    bundlesDir: path.join(dataDir, 'bundles'),
    importsDir: path.join(dataDir, 'imports'),
    offlineDir: path.join(dataDir, 'offline'),
    buildsDir: path.join(dataDir, 'builds'),
    publicDir: path.join(PKG_ROOT, 'web'),
    host,
    winHost,
    domain,
    disk: String(env.IMAGE_STUDIO_DISK || '/var/lib/libvirt/images/win11-stock.raw'),
    partition: String(env.IMAGE_STUDIO_PARTITION || '/dev/nbd0p3'),
    nbd: String(env.IMAGE_STUDIO_NBD || '/dev/nbd0'),
    mount: String(env.IMAGE_STUDIO_MOUNT || '/mnt/win11-offline'),
    backupDir: String(env.IMAGE_STUDIO_BACKUP || '/root/image-studio-backups'),
    nixosRepo: String(env.IMAGE_STUDIO_NIXOS_REPO || '/etc/nixos'),
    windowsRepo: String(env.IMAGE_STUDIO_WINDOWS_REPO || '/etc/nixos/windows'),
    bind: String(env.IMAGE_STUDIO_BIND || '127.0.0.1'),
    port: envInt(env.IMAGE_STUDIO_PORT, 8788),
    token,
    dryRun: envBool(env.IMAGE_STUDIO_DRY_RUN),
    docker: env.IMAGE_STUDIO_DOCKER === undefined ? true : envBool(env.IMAGE_STUDIO_DOCKER),
    strictHostKey: env.IMAGE_STUDIO_SSH_STRICT === undefined ? 'accept-new' : String(env.IMAGE_STUDIO_SSH_STRICT),
    timeoutMs: envInt(env.IMAGE_STUDIO_TIMEOUT_MS, 45 * 60 * 1000),
    maxUpload: envInt(env.IMAGE_STUDIO_MAX_UPLOAD, 16 * 1024 * 1024 * 1024),
    sudo: env.IMAGE_STUDIO_SUDO === undefined ? true : envBool(env.IMAGE_STUDIO_SUDO, true),
  };
}

/** Path as seen by the host that runs libvirt/nix/qemu-nbd. */
export function hostRepoPath(config, relative) {
  return path.posix.join(config.nixosRepo.replace(/\/+$/, ''), relative);
}

/** Path as seen by the controller (used for local reads/tests). */
export function localRepoPath(config, relative) {
  return path.join(config.repoRoot, relative);
}