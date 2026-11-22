import test from 'node:test';
import assert from 'node:assert/strict';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { loadConfig } from '../src/config.js';
import { LiveSystem } from '../src/live.js';

class FakeLiveRunner {
  constructor() {
    this.scripts = [];
    this.streams = [];
    this.calls = [];
  }
  async guestPowerShell(script) {
    this.scripts.push(script);
    return { ok: true, code: 0, stdout: '{}', stderr: '', output: '{}' };
  }
  async guestPowerShellStream(script) {
    this.streams.push(script);
    return { ok: true, code: 0, stdout: '', stderr: '', output: '' };
  }
  async runGuest(argv) {
    this.calls.push(['guest', ...argv]);
    return { ok: true, code: 0, stdout: 'ok', stderr: '', output: 'ok' };
  }
  async runHost(argv) {
    this.calls.push(['host', ...argv]);
    if (argv[0] === 'virsh') return { ok: true, code: 0, stdout: 'shut off\n', stderr: '', output: 'shut off\n' };
    return { ok: true, code: 0, stdout: '', stderr: '', output: '' };
  }
  async runHostSudo(argv) {
    this.calls.push(['sudo', ...argv]);
    return { ok: true, code: 0, stdout: '', stderr: '', output: '' };
  }
  async runHostShell(script) {
    this.calls.push(['shell', script]);
    return { ok: true, code: 0, stdout: '', stderr: '', output: '' };
  }
}

async function fixture() {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'image-studio-live-'));
  const config = loadConfig({
    ...process.env,
    IMAGE_STUDIO_DATA: path.join(dir, 'var'),
    IMAGE_STUDIO_HOST: '',
    IMAGE_STUDIO_DRY_RUN: '0',
  });
  const runner = new FakeLiveRunner();
  return { config, runner, live: new LiveSystem(config, runner) };
}

test('Windows scripts contain single-backslash registry and path literals', async () => {
  const { live, runner } = await fixture();
  await live.winVerify();
  await live.winRdpLimits({ confirm: 'RUN' });
  await live.winAutologon({ enabled: true, user: 'Windows-PC', domain: 'WINDOWS-VM', confirm: 'RUN' });
  await live.winRemoveStore({ confirm: 'RUN' });
  await live.winRemoveEdge({ confirm: 'RUN' });
  await live.winAppxRemove({ names: 'MicrosoftWindows.Client.CoreAI', endOfLife: true, confirm: 'RUN' });
  const text = runner.scripts.join('\n');
  assert.ok(text.includes("HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon"));
  assert.ok(text.includes("HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services"));
  assert.ok(text.includes("HKLM:\\SOFTWARE\\Policies\\Microsoft\\WindowsStore"));
  assert.ok(text.includes("Join-Path $env:LOCALAPPDATA 'Microsoft\\OneDrive'"));
  assert.ok(text.includes("C:\\Program Files (x86)\\Microsoft\\Edge"));
  assert.ok(text.includes("\\Microsoft\\Windows\\InstallService\\*"));
  assert.ok(text.includes("\\Microsoft\\Windows\\WindowsAI\\*"));
  assert.ok(text.includes("HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\EndOfLife"));
});

test('win_ssh_exec and VM helpers call the expected targets', async () => {
  const { live, runner } = await fixture();
  await live.winSshExec({ argv: ['qwinsta'], confirm: 'RUN' });
  assert.deepEqual(runner.calls.find((call) => call[0] === 'guest'), ['guest', 'qwinsta']);

  const state = await live.vmState();
  assert.equal(state.state, 'shut off');

  await live.vmMemory({ gib: 4, confirm: 'RESIZE' });
  const memory = runner.calls.find((call) => call.join(' ').includes('/scripts/vm-memory.sh'));
  assert.ok(memory);
  assert.ok(memory.includes('4'));
});

test('winServiceSet validates names and startup types', async () => {
  const { live } = await fixture();
  await assert.rejects(() => live.winServiceSet({ name: 'bad name', startupType: 'Disabled', confirm: 'RUN' }), /service name/);
  await assert.rejects(() => live.winServiceSet({ name: 'DoSvc', startupType: 'Sometimes', confirm: 'RUN' }), /startupType/);
  await assert.rejects(() => live.winServiceSet({ name: 'DoSvc', startupType: 'Disabled', confirm: 'NO' }), /confirm/);
});