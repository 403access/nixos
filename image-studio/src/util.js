import { createHash, randomUUID } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

/** POSIX shell single-quote. */
export function shQuote(value) {
  const s = String(value);
  if (s === '') return "''";
  return `'${s.replace(/'/g, "'\\''")}'`;
}

/** PowerShell single-quote. */
export function psQuote(value) {
  return `'${String(value).replace(/'/g, "''")}'`;
}

/** Safe double-quoted Nix string. */
export function nixString(value) {
  return JSON.stringify(String(value)).replace(/\$\{/g, '\\${');
}

export function nowIso() {
  return new Date().toISOString();
}

export function createId(prefix = 'job') {
  return `${prefix}-${Date.now().toString(36)}-${randomUUID().slice(0, 8)}`;
}

export function safeName(value, label = 'name') {
  const s = String(value ?? '').trim();
  if (!s || s.length > 128 || s.startsWith('.') || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(s)) {
    throw new Error(`${label} must match ^[A-Za-z0-9][A-Za-z0-9._-]*$ and be at most 128 characters`);
  }
  return s;
}

/** Resolve a relative path below root and reject escapes. */
export function safeJoin(root, ...parts) {
  const base = path.resolve(root);
  const target = path.resolve(base, ...parts.map(String));
  if (target !== base && !target.startsWith(`${base}${path.sep}`)) {
    throw new Error(`path escapes ${base}: ${parts.join('/')}`);
  }
  return target;
}

/** Normalize a Windows-relative path and reject traversal/absolute paths. */
export function safeWindowsRelative(value) {
  const raw = String(value ?? '').replace(/\\/g, '/');
  if (!raw || raw.includes('\0')) throw new Error('path is empty');
  if (raw.startsWith('/')) throw new Error('absolute paths are not allowed');
  const parts = raw.split('/').filter((part) => part !== '' && part !== '.');
  if (parts.some((part) => part === '..')) throw new Error('path traversal is not allowed');
  if (/^[A-Za-z]:/.test(parts[0] ?? '')) throw new Error('absolute Windows paths are not allowed');
  return parts.join('/');
}

export function ensureDir(dir) {
  return fs.mkdir(dir, { recursive: true });
}

export async function readJson(file, fallback = null) {
  try {
    return JSON.parse(await fs.readFile(file, 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return fallback;
    throw error;
  }
}

export async function writeJson(file, value) {
  await ensureDir(path.dirname(file));
  const tmp = `${file}.${process.pid}.tmp`;
  await fs.writeFile(tmp, `${JSON.stringify(value, null, 2)}\n`);
  await fs.rename(tmp, file);
  return value;
}

export async function sha256File(file) {
  const hash = createHash('sha256');
  const stream = (await import('node:fs')).createReadStream(file);
  for await (const chunk of stream) hash.update(chunk);
  return hash.digest('hex');
}

export async function tailFile(file, maxBytes = 64 * 1024) {
  try {
    const handle = await fs.open(file, 'r');
    try {
      const stat = await handle.stat();
      const start = Math.max(0, stat.size - maxBytes);
      const buffer = Buffer.alloc(stat.size - start);
      await handle.read(buffer, 0, buffer.length, start);
      return buffer.toString('utf8');
    } finally {
      await handle.close();
    }
  } catch (error) {
    if (error.code === 'ENOENT') return '';
    throw error;
  }
}

export function redact(value) {
  if (Array.isArray(value)) return value.map(redact);
  if (!value || typeof value !== 'object') return value;
  const out = {};
  for (const [key, item] of Object.entries(value)) {
    out[key] = /password|passwd|secret|token|key$/i.test(key) ? '[redacted]' : redact(item);
  }
  return out;
}

export function requireConfirm(value, expected = 'YES') {
  if (value !== expected) {
    throw new Error(`refusing destructive operation: pass confirm=${JSON.stringify(expected)}`);
  }
}

export function humanBytes(bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  let value = Number(bytes) || 0;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${unit === 0 ? value : value.toFixed(1)} ${units[unit]}`;
}

/** Parse JSON printed as the only line/object of a command. */
export function parseJsonOutput(text) {
  const trimmed = String(text ?? '').trim();
  if (!trimmed) return null;
  try {
    return JSON.parse(trimmed);
  } catch {
    const start = Math.min(
      ...['{', '['].map((char) => {
        const index = trimmed.indexOf(char);
        return index === -1 ? Number.MAX_SAFE_INTEGER : index;
      }),
    );
    if (start === Number.MAX_SAFE_INTEGER) throw new Error('no JSON object in command output');
    const end = Math.max(trimmed.lastIndexOf('}'), trimmed.lastIndexOf(']'));
    if (end <= start) throw new Error('unterminated JSON in command output');
    return JSON.parse(trimmed.slice(start, end + 1));
  }
}

/** True when the value is a plain object (not array/null). */
export function isObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

export function clampInt(value, min, max, fallback) {
  const n = Number(value);
  if (!Number.isInteger(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

export function assertEnum(value, allowed, label) {
  if (!allowed.includes(value)) {
    throw new Error(`${label} must be one of: ${allowed.join(', ')}`);
  }
  return value;
}

export function assertRegex(value, regex, label) {
  if (!regex.test(String(value))) throw new Error(`${label} has an invalid format`);
  return String(value);
}