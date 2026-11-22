import path from 'node:path';
import { createId, ensureDir, nowIso, readJson, requireConfirm, safeWindowsRelative, shQuote, writeJson } from './util.js';

const HIVES = ['SYSTEM', 'SOFTWARE', 'SAM', 'SECURITY', 'DEFAULT'];
const START_VALUES = {
  boot: 0,
  system: 1,
  auto: 2,
  automatic: 2,
  manual: 3,
  demand: 3,
  disabled: 4,
};

function normalizeHive(hive) {
  const name = String(hive || '').toUpperCase();
  if (!HIVES.includes(name)) throw new Error(`hive must be one of: ${HIVES.join(', ')}`);
  return name;
}

function normalizeKey(key) {
  let value = String(key || '').replace(/\//g, '\\').replace(/\\+/g, '\\');
  if (!value.startsWith('\\')) value = `\\${value}`;
  if (/[\0\r\n\[\]"]/.test(value) || value.length > 1024) throw new Error('registry key contains unsafe characters');
  return value;
}

function normalizeValueName(name) {
  const value = String(name || '');
  if (!/^[A-Za-z0-9_.@-]{1,128}$/.test(value)) throw new Error('invalid registry value name');
  return value;
}

function hiveRegRoot(hive) {
  return `HKEY_LOCAL_MACHINE\\${normalizeHive(hive)}`;
}

function startValue(value) {
  if (Number.isInteger(Number(value)) && Number(value) >= 0 && Number(value) <= 4) return Number(value);
  const key = String(value || '').toLowerCase();
  if (!(key in START_VALUES)) throw new Error('start must be boot, system, auto, manual, disabled or 0-4');
  return START_VALUES[key];
}

export class OfflineImage {
  constructor(config, runner) {
    this.config = config;
    this.runner = runner;
  }

  statePath(domain = this.config.domain) {
    return path.join(this.config.offlineDir, `${domain}.json`);
  }

  async state(domain = this.config.domain) {
    return readJson(this.statePath(domain), null);
  }

  async saveState(state) {
    await ensureDir(this.config.offlineDir);
    await writeJson(this.statePath(state.domain), state);
    return state;
  }

  async clearState(domain = this.config.domain) {
    await ensureDir(this.config.offlineDir);
    await writeJson(this.statePath(domain), { domain, mounted: false, updatedAt: nowIso() });
  }

  async vmState(domain = this.config.domain) {
    const result = await this.runner.runHost(['virsh', '-c', 'qemu:///system', 'domstate', domain], { timeoutMs: 30_000 });
    if (result.ok) return result.stdout.trim();
    const sudo = await this.runner.runHostSudo(['virsh', '-c', 'qemu:///system', 'domstate', domain], { timeoutMs: 30_000 });
    return sudo.ok ? sudo.stdout.trim() : `unknown (${result.output.trim() || result.error})`;
  }

  async isMounted(mount = this.config.mount) {
    const result = await this.runner.runHostShell(`mountpoint -q ${shQuote(mount)}`, { timeoutMs: 30_000 });
    return result.ok;
  }

  async status({ domain = this.config.domain } = {}) {
    const state = await this.state(domain);
    const mounted = state?.mount ? await this.isMounted(state.mount) : false;
    return {
      domain,
      vmState: await this.vmState(domain),
      mounted,
      state: state || null,
      disk: this.config.disk,
      partition: this.config.partition,
    };
  }

  async mount({ readOnly = false, force = false, confirm, domain = this.config.domain } = {}) {
    requireConfirm(confirm, 'MOUNT');
    const existing = await this.state(domain);
    if (existing?.mounted && await this.isMounted(existing.mount)) {
      return this.status({ domain });
    }
    const vmState = await this.vmState(domain);
    if (!/shut off/i.test(vmState) && !force) {
      throw new Error(`domain ${domain} is "${vmState}"; shut it down or pass force=true`);
    }

    await this.runner.runHostSudo(['modprobe', 'nbd', 'max_part=16'], { timeoutMs: 60_000 });
    await this.runner.runHostSudo(['mkdir', '-p', this.config.mount], { timeoutMs: 30_000 });

    const attach = await this.runner.runHostSudo(
      ['qemu-nbd', '-f', 'raw', '-c', this.config.nbd, this.config.disk],
      { timeoutMs: 60_000 },
    );
    if (!attach.ok && !/busy|in use/i.test(attach.output)) {
      throw new Error(`qemu-nbd failed: ${attach.output.trim() || attach.error}`);
    }

    const mountArgs = ['ntfs-3g'];
    if (readOnly) mountArgs.push('-o', 'ro');
    mountArgs.push(this.config.partition, this.config.mount);
    const mounted = await this.runner.runHostSudo(mountArgs, { timeoutMs: 120_000 });
    if (!mounted.ok) {
      await this.runner.runHostSudo(['qemu-nbd', '-d', this.config.nbd], { timeoutMs: 30_000 }).catch(() => {});
      throw new Error(`mount failed: ${mounted.output.trim() || mounted.error}`);
    }

    await this.saveState({
      domain,
      mounted: true,
      disk: this.config.disk,
      partition: this.config.partition,
      nbd: this.config.nbd,
      mount: this.config.mount,
      readOnly: Boolean(readOnly),
      createdAt: nowIso(),
    });
    return this.status({ domain });
  }

  async umount({ confirm, domain = this.config.domain } = {}) {
    requireConfirm(confirm, 'UMOUNT');
    const state = await this.state(domain);
    await this.runner.runHostSudo(['umount', state?.mount || this.config.mount], { timeoutMs: 120_000 }).catch(() => {});
    await this.runner.runHostSudo(['qemu-nbd', '-d', state?.nbd || this.config.nbd], { timeoutMs: 60_000 }).catch(() => {});
    await this.clearState(domain);
    return { domain, mounted: false, updatedAt: nowIso() };
  }

  async requireMounted({ write = false, domain = this.config.domain } = {}) {
    const state = await this.state(domain);
    if (!state?.mounted) throw new Error('image is not mounted; call offline_mount first');
    if (!(await this.isMounted(state.mount))) throw new Error(`mount ${state.mount} disappeared`);
    if (write && state.readOnly) throw new Error('image is mounted read-only; remount read-write');
    return state;
  }

  hivePath(hive, state) {
    return path.posix.join(state.mount, 'Windows/System32/config', normalizeHive(hive));
  }

  async hivexsh(hive, commands, { write = false, domain = this.config.domain } = {}) {
    const state = await this.requireMounted({ write, domain });
    const argv = ['hivexsh', ...(write ? ['-w'] : []), this.hivePath(hive, state)];
    const result = await this.runner.runHostSudo(argv, { input: commands, timeoutMs: 120_000 });
    if (!result.ok) throw new Error(`hivexsh failed: ${result.output.trim() || result.error}`);
    return result;
  }

  async hiveGet(hive, key, { domain = this.config.domain } = {}) {
    const normalized = normalizeKey(key);
    const result = await this.hivexsh(hive, `cd ${normalized}\nlsval\nquit\n`, { domain });
    return { hive: normalizeHive(hive), key: normalized, output: result.stdout };
  }

  async hiveKeyExists(hive, key, { domain = this.config.domain } = {}) {
    const normalized = normalizeKey(key);
    try {
      const result = await this.hivexsh(hive, `cd ${normalized}\nls\nquit\n`, { domain });
      return !/(no such|cd:|not found|invalid)/i.test(`${result.stdout}\n${result.stderr}`);
    } catch {
      return false;
    }
  }

  async hiveDeleteKey(hive, key, { confirm, domain = this.config.domain } = {}) {
    requireConfirm(confirm, 'WRITE');
    const normalized = normalizeKey(key);
    await this.hivexsh(hive, `cd ${normalized}\ndel\ncommit\nquit\n`, { write: true, domain });
    return { hive: normalizeHive(hive), key: normalized, deleted: !(await this.hiveKeyExists(hive, normalized, { domain })) };
  }

  async hiveSetDword(hive, key, name, value, { confirm, domain = this.config.domain } = {}) {
    requireConfirm(confirm, 'WRITE');
    const normalized = normalizeKey(key);
    const valueName = normalizeValueName(name);
    const dword = Number(value);
    if (!Number.isInteger(dword) || dword < 0 || dword > 0xffffffff) throw new Error('value must be a 32-bit unsigned integer');
    const state = await this.requireMounted({ write: true, domain });
    const tmp = `/tmp/image-studio-${createId('hive')}.reg`;
    const hex = (dword >>> 0).toString(16).padStart(8, '0');
    const body = `Windows Registry Editor Version 5.00\n\n[${hiveRegRoot(hive)}${normalized}]\n"${valueName}"=dword:${hex}\n`;
    const write = await this.runner.hostWriteFile(tmp, body, { privileged: true });
    if (!write.ok) throw new Error(`cannot stage registry file: ${write.output.trim() || write.error}`);
    try {
      const result = await this.runner.runHostSudo(
        ['reged', '-C', '-I', this.hivePath(hive, state), hiveRegRoot(hive), tmp],
        { timeoutMs: 120_000 },
      );
      if (!result.ok) throw new Error(`reged failed: ${result.output.trim() || result.error}`);
    } finally {
      await this.runner.runHostSudo(['rm', '-f', tmp], { timeoutMs: 30_000 }).catch(() => {});
    }
    return { hive: normalizeHive(hive), key: normalized, name: valueName, value: dword };
  }

  async removePath(relative, { confirm, domain = this.config.domain } = {}) {
    requireConfirm(confirm, 'REMOVE');
    const clean = safeWindowsRelative(relative);
    if (/^Windows\/System32\/config(\/|$)/i.test(clean)) throw new Error('refusing to remove registry hives');
    const state = await this.requireMounted({ write: true, domain });
    const target = path.posix.join(state.mount, clean);
    const result = await this.runner.runHostSudo(['rm', '-rf', '--', target], { timeoutMs: 300_000 });
    if (!result.ok) throw new Error(`remove failed: ${result.output.trim() || result.error}`);
    return { target, removed: true };
  }

  async removeGlob(pattern, { confirm, domain = this.config.domain } = {}) {
    requireConfirm(confirm, 'REMOVE');
    const clean = safeWindowsRelative(pattern);
    if (!/^Windows\/WinSxS\//.test(clean)) throw new Error('glob removal is limited to Windows/WinSxS');
    const base = path.posix.dirname(clean);
    const name = path.posix.basename(clean);
    if (!/^[A-Za-z0-9._*?-]+$/.test(name)) throw new Error('unsafe glob pattern');
    const state = await this.requireMounted({ write: true, domain });
    const dir = path.posix.join(state.mount, base);
    const script = `for p in ${shQuote(dir)}/${name}; do [ -e "$p" ] && rm -rf -- "$p"; done`;
    const result = await this.runner.runHostSudo(['sh', '-c', script], { timeoutMs: 300_000 });
    if (!result.ok) throw new Error(`remove failed: ${result.output.trim() || result.error}`);
    return { pattern: clean, removed: true };
  }

  async backupHives({ confirm, domain = this.config.domain } = {}) {
    requireConfirm(confirm, 'BACKUP');
    const state = await this.requireMounted({ domain });
    const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..+$/, '');
    const dir = path.posix.join(this.config.backupDir, `${domain}-${stamp}`);
    await this.runner.runHostSudo(['mkdir', '-p', dir], { timeoutMs: 30_000 });
    const files = [];
    for (const hive of ['SYSTEM', 'SOFTWARE']) {
      const source = this.hivePath(hive, state);
      const result = await this.runner.runHostSudo(['cp', '-a', '--', source, path.posix.join(dir, `${hive}.bak`)], {
        timeoutMs: 300_000,
      });
      if (result.ok) files.push(`${hive}.bak`);
    }
    return { backupDir: dir, files };
  }

  async aiRemove({ confirm, domain = this.config.domain } = {}) {
    requireConfirm(confirm, 'AI-REMOVE');
    await this.requireMounted({ write: true, domain });
    const backup = await this.backupHives({ confirm: 'BACKUP', domain });

    const removed = [];
    for (const relative of [
      'Windows/SystemApps/MicrosoftWindows.Client.CoreAI_cw5n1h2txyewy',
      'Windows/SystemApps/Microsoft.AIFabric.CBS.1.6_8wekyb3d8bbwe',
      'Windows/System32/Tasks/Microsoft/Windows/WindowsAI',
    ]) {
      const result = await this.removePath(relative, { confirm: 'REMOVE', domain });
      removed.push(result.target);
    }
    for (const pattern of [
      'Windows/WinSxS/amd64_userexperience-coreai_*',
      'Windows/WinSxS/amd64_microsoft-aifabric-cbs-1-6_*',
    ]) {
      await this.removeGlob(pattern, { confirm: 'REMOVE', domain });
      removed.push(pattern);
    }

    const keys = [
      '\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\InboxApplications\\MicrosoftWindows.Client.CoreAI_1000.26100.10068.0_x64__cw5n1h2txyewy',
      '\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\InboxApplications\\Microsoft.AIFabric.CBS.1.6_1.6.955.100_x64__8wekyb3d8bbwe',
    ];
    const deletedKeys = [];
    for (const key of keys) {
      const result = await this.hiveDeleteKey('SOFTWARE', key, { confirm: 'WRITE', domain });
      deletedKeys.push(result);
    }

    return { backup, removed, deletedKeys, note: 'Boot the VM and verify Get-AppxPackage, WindowsAI tasks and DISM /CheckHealth.' };
  }

  async serviceSet(name, start, { confirm, domain = this.config.domain } = {}) {
    const service = String(name || '');
    if (!/^[A-Za-z0-9_.-]{1,128}$/.test(service)) throw new Error('invalid service name');
    return this.hiveSetDword('SYSTEM', `\\ControlSet001\\Services\\${service}`, 'Start', startValue(start), {
      confirm,
      domain,
    });
  }

  async harden(mode, { confirm, domain = this.config.domain } = {}) {
    requireConfirm(confirm, 'HARDEN');
    const allowed = ['search', 'defender', 'all'];
    if (!allowed.includes(mode)) throw new Error(`mode must be one of: ${allowed.join(', ')}`);
    const script = path.join(this.config.nixosRepo, 'scripts/windows/offline/apply.sh');
    const result = await this.runner.runHostSudo([
      'bash',
      script,
      '--mode', mode,
      '--domain', domain,
      '--disk', this.config.disk,
      '--backup-dir', this.config.backupDir,
    ], { timeoutMs: 20 * 60 * 1000 });
    return { mode, ok: result.ok, output: result.output };
  }
}