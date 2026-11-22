import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');

function startServer(env) {
  const child = spawn(process.execPath, [path.join(ROOT, 'src/mcp.js')], {
    cwd: ROOT,
    env: { ...process.env, ...env },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const rl = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
  const pending = new Map();
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
  rl.on('line', (line) => {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message);
      pending.delete(message.id);
    }
  });
  const send = (message) => child.stdin.write(`${JSON.stringify(message)}\n`);
  const request = (id, method, params = {}) => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timeout waiting for ${method}\n${stderr}`)), 8000);
    pending.set(id, (message) => {
      clearTimeout(timer);
      resolve(message);
    });
    send({ jsonrpc: '2.0', id, method, params });
  });
  return { child, request, send, stderr: () => stderr };
}

test('MCP initialize, tools/list and a tool call', async (t) => {
  const data = await fsp.mkdtemp(path.join(os.tmpdir(), 'image-studio-mcp-'));
  const server = startServer({
    IMAGE_STUDIO_DATA: data,
    IMAGE_STUDIO_DRY_RUN: '1',
    IMAGE_STUDIO_HOST: '',
  });
  t.after(() => {
    server.child.stdin.end();
    server.child.kill('SIGKILL');
  });

  const init = await server.request(1, 'initialize', {
    protocolVersion: '2024-11-05',
    capabilities: {},
    clientInfo: { name: 'test', version: '1' },
  });
  assert.equal(init.result.serverInfo.name, 'image-studio');
  assert.ok(init.result.capabilities.tools);

  const list = await server.request(2, 'tools/list');
  const names = list.result.tools.map((tool) => tool.name);
  for (const expected of [
    'system_capabilities',
    'nixos_config_read',
    'win_verify',
    'offline_ai_remove',
    'image_build_nixos',
    'image_build_windows',
    'image_bundle_export',
    'image_bundle_import',
    'tests_run',
  ]) {
    assert.ok(names.includes(expected), `missing ${expected}`);
  }

  const info = await server.request(3, 'tools/call', { name: 'image_studio_info', arguments: {} });
  assert.equal(info.result.isError, false);
  const parsed = JSON.parse(info.result.content[0].text);
  assert.equal(parsed.version, '0.1.0');
  assert.equal(parsed.config.dryRun, true);

  const validated = await server.request(4, 'tools/call', {
    name: 'image_validate',
    arguments: { kind: 'windows', profile: { name: 'mcp-test', profile: 'lean', sourceIso: '/tmp/Win11.iso' } },
  });
  assert.equal(validated.result.isError, false);
  assert.equal(JSON.parse(validated.result.content[0].text).kind, 'windows');

  const bad = await server.request(5, 'tools/call', {
    name: 'image_validate',
    arguments: { kind: 'windows', profile: { sourceIso: 'relative.iso' } },
  });
  assert.equal(bad.result.isError, true);
  assert.match(bad.result.content[0].text, /absolute/);

  const build = await server.request(6, 'tools/call', {
    name: 'image_build_nixos',
    arguments: { profile: { name: 'mcp-nixos', hostName: 'mcp-nixos' } },
  });
  assert.equal(build.result.isError, false);
  const built = JSON.parse(build.result.content[0].text);
  assert.equal(built.job.kind, 'nixos');
  assert.equal(built.job.status, 'succeeded');

  const status = await server.request(7, 'tools/call', {
    name: 'image_job_status',
    arguments: { id: built.job.id },
  });
  assert.equal(status.result.isError, false);
  assert.equal(JSON.parse(status.result.content[0].text).job.id, built.job.id);
});

test('MCP returns method-not-found for unknown methods', async (t) => {
  const data = await fsp.mkdtemp(path.join(os.tmpdir(), 'image-studio-mcp-'));
  const server = startServer({
    IMAGE_STUDIO_DATA: data,
    IMAGE_STUDIO_DRY_RUN: '1',
    IMAGE_STUDIO_HOST: '',
  });
  t.after(() => {
    server.child.stdin.end();
    server.child.kill('SIGKILL');
  });
  const response = await server.request(1, 'does/not/exist');
  assert.equal(response.error.code, -32601);
});