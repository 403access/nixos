import test from 'node:test';
import assert from 'node:assert/strict';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { loadConfig } from '../src/config.js';
import { OfflineImage } from '../src/offline.js';
import { ensureDir, writeJson } from '../src/util.js';

class FakeRunner {
  constructor(config) {
    this.config = config;
    this.calls = [];
    this.files = new Map();
  }
  async runHost(argv) {
    this.calls.push(['host', ...argv]);
    if (argv[0] === 'virsh') return { ok: true, code: 0, stdout: 'shut off\n', stderr: '', output: 'shut off\n' };
    return { ok: true, code: 0, stdout: '', stderr: '', output: '' };
  }
  async runHostSudo(argv, opts = {}) {
    this.calls.push(['sudo', ...argv, opts.input ? `<<${opts.input.length}` : '']);
    return { ok: true, code: 0, stdout: '', stderr: '', output: '' };
  }
  async runHostShell(script) {
    this.calls.push(['shell', script]);
    return { ok: true, code: 0, stdout: '', stderr: '', output: '' };
  }
  async hostWriteFile(file, content) {
    this.files.set(file, content);
    return { ok: true, code: 0, stdout: '', stderr: '', output: '' };
  }
}

async function fixture() {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'image-studio-offline-'));
  const config = loadConfig({
    ...process.env,
    IMAGE_STUDIO_DATA: path.join(dir, 'var'),
    IMAGE_STUDIO_HOST: '',
    IMAGE_STUDIO_DRY_RUN: '0',
  });
  await ensureDir(config.offlineDir);
  await writeJson(offlineStateFile(config), {
    domain: config.domain,
    mounted: true,
    mount: config.mount,
    readOnly: false,
    disk: config.disk,
    partition: config.partition,
    nbd: config.nbd,
  });
  const runner = new FakeRunner(config);
  const offline = new OfflineImage(config, runner);
  return { dir, config, runner, offline };
}

function offlineStateFile(config) {
  return path.join(config.offlineDir, `${config.domain}.json`);
}

test('offline mount issues qemu-nbd and ntfs-3g commands', async () => {
  const { config, runner, offline } = await fixture();
  await fsp.rm(offlineStateFile(config), { force: true });
  const status = await offline.mount({ confirm: 'MOUNT' });
  assert.equal(status.mounted, true);
  const all = runner.calls.map((call) => call.join(' ')).join('\n');
  assert.match(all, /qemu-nbd -f raw -c \/dev\/nbd0/);
  assert.match(all, /ntfs-3g/);
  assert.equal(status.vmState, 'shut off');
});

test('mount refuses a running VM without force', async () => {
  const { runner, offline, config } = await fixture();
  await fsp.rm(offlineStateFile(config), { force: true });
  runner.runHost = async (argv) => {
    if (argv[0] === 'virsh') return { ok: true, stdout: 'running\n', stderr: '', output: 'running\n' };
    return { ok: true, stdout: '', stderr: '', output: '' };
  };
  await assert.rejects(() => offline.mount({ confirm: 'MOUNT' }), /running/);
});

test('hiveSetDword stages a reg file and runs reged', async () => {
  const { runner, offline, config } = await fixture();
  const result = await offline.hiveSetDword(
    'SYSTEM',
    '\\ControlSet001\\Services\\DoSvc',
    'Start',
    4,
    { confirm: 'WRITE', domain: config.domain },
  );
  assert.equal(result.value, 4);
  const regFile = [...runner.files.entries()].find(([file]) => file.endsWith('.reg'));
  assert.ok(regFile, 'reg file was staged');
  assert.match(regFile[1], /\[HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\Services\\DoSvc\]/);
  assert.match(regFile[1], /"Start"=dword:00000004/);
  assert.ok(runner.calls.some((call) => call.includes('reged')));
});

test('offline serviceSet and removePath enforce confirmations and safety', async () => {
  const { runner, offline, config } = await fixture();
  const service = await offline.serviceSet('DoSvc', 'disabled', { confirm: 'WRITE', domain: config.domain });
  assert.equal(service.name, 'Start');
  await assert.rejects(() => offline.removePath('Windows/System32/config/SOFTWARE', { confirm: 'REMOVE' }), /hives/);
  await assert.rejects(() => offline.removePath('../../etc/passwd', { confirm: 'REMOVE' }), /traversal/);
  await offline.removePath('Windows/SystemApps/Foo', { confirm: 'REMOVE', domain: config.domain });
  const rm = runner.calls.find((call) => call.includes('rm') && call.join(' ').includes('Foo'));
  assert.ok(rm);
  assert.ok(rm.join(' ').includes('/mnt/win11-offline/Windows/SystemApps/Foo'));
});

test('umount clears state', async () => {
  const { offline, config } = await fixture();
  const result = await offline.umount({ confirm: 'UMOUNT', domain: config.domain });
  assert.equal(result.mounted, false);
});