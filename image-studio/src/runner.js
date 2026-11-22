import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { humanBytes, nowIso, shQuote } from './util.js';

const MAX_CAPTURE = 4 * 1024 * 1024;

export function commandLine(argv) {
  return argv.map((part) => (/^[A-Za-z0-9_./:@%+=,-]+$/.test(String(part)) ? String(part) : shQuote(part))).join(' ');
}

export function redactCommand(argv) {
  const out = [];
  for (let i = 0; i < argv.length; i += 1) {
    const part = String(argv[i]);
    out.push(part);
    if (/^--?(password|passwd|token|secret)$/i.test(part) && i + 1 < argv.length) {
      out.push('[redacted]');
      i += 1;
    }
  }
  return commandLine(out);
}

export class Runner {
  constructor(config, { spawnImpl = spawn } = {}) {
    this.config = config;
    this.spawnImpl = spawnImpl;
    this._capabilities = null;
  }

  sshArgs(target, { jump = '' } = {}) {
    const args = [
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=10',
      '-o',
      `StrictHostKeyChecking=${this.config.strictHostKey}`,
    ];
    if (jump) args.push('-J', jump);
    args.push(target);
    return args;
  }

  execFile(program, args = [], opts = {}) {
    const {
      input,
      timeoutMs = 120_000,
      cwd,
      env,
      maxOutput = MAX_CAPTURE,
    } = opts;

    return new Promise((resolve) => {
      const started = Date.now();
      let child;
      try {
        child = this.spawnImpl(program, args, {
          cwd,
          env: env ? { ...process.env, ...env } : process.env,
          stdio: ['pipe', 'pipe', 'pipe'],
        });
      } catch (error) {
        resolve({ ok: false, code: null, stdout: '', stderr: '', output: '', error: error.message, argv: [program, ...args], startedAt: nowIso() });
        return;
      }

      let stdout = '';
      let stderr = '';
      let truncated = false;
      let timedOut = false;
      let settled = false;

      const append = (current, chunk) => {
        const text = chunk.toString('utf8');
        if (current.length + text.length > maxOutput) {
          truncated = true;
          return current + text.slice(0, Math.max(0, maxOutput - current.length));
        }
        return current + text;
      };

      const finish = (code, error = null) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        const elapsedMs = Date.now() - started;
        resolve({
          ok: code === 0 && !error && !timedOut,
          code,
          stdout,
          stderr,
          output: stdout + stderr,
          error,
          timedOut,
          truncated,
          elapsedMs,
          argv: [program, ...args],
          command: redactCommand([program, ...args]),
          startedAt: new Date(started).toISOString(),
        });
      };

      child.stdout?.on('data', (chunk) => { stdout = append(stdout, chunk); });
      child.stderr?.on('data', (chunk) => { stderr = append(stderr, chunk); });
      child.on('error', (error) => finish(null, error.message));
      child.on('close', (code) => finish(code));

      const timer = setTimeout(() => {
        timedOut = true;
        try { child.kill('SIGKILL'); } catch { /* ignore */ }
      }, Math.max(1, timeoutMs));

      if (input !== undefined && input !== null) {
        child.stdin?.end(input);
      } else {
        child.stdin?.end();
      }
    });
  }

  async runHost(argv, opts = {}) {
    if (this.config.dryRun) {
      return this.dryRun(argv, opts);
    }
    if (this.config.host) {
      return this.execFile('ssh', [...this.sshArgs(this.config.host), '--', argv.map(shQuote).join(' ')], opts);
    }
    return this.execFile(argv[0], argv.slice(1), opts);
  }

  /** Wrap an argv for the build host without running it (used by jobs). */
  wrapHost(argv, { sudo = false } = {}) {
    const full = sudo && this.config.sudo ? ['sudo', '-n', ...argv] : argv;
    if (!this.config.host) return full;
    return [
      'ssh',
      ...this.sshArgs(this.config.host),
      '--',
      full.map(shQuote).join(' '),
    ];
  }

  async runHostSudo(argv, opts = {}) {
    if (this.config.dryRun) return this.dryRun(argv, opts);
    const full = this.config.sudo ? ['sudo', '-n', ...argv] : argv;
    return this.runHost(full, opts);
  }

  async runHostShell(script, opts = {}) {
    if (this.config.dryRun) return this.dryRun(['sh', '-lc', script], opts);
    if (this.config.host) {
      return this.execFile('ssh', [...this.sshArgs(this.config.host), '--', `sh -lc ${shQuote(script)}`], opts);
    }
    return this.execFile('sh', ['-lc', script], opts);
  }

  async runGuest(argv, opts = {}) {
    if (this.config.dryRun) return this.dryRun(argv, opts);
    if (!this.config.host) {
      return {
        ok: false,
        code: null,
        stdout: '',
        stderr: '',
        output: '',
        error: 'IMAGE_STUDIO_HOST is required for guest operations',
        argv,
      };
    }
    return this.execFile('ssh', [...this.sshArgs(this.config.winHost, { jump: this.config.host }), '--', argv.map(shQuote).join(' ')], opts);
  }

  async guestPowerShell(script, opts = {}) {
    const encoded = Buffer.from(String(script), 'utf16le').toString('base64');
    return this.runGuest(
      ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded],
      { timeoutMs: 120_000, ...opts },
    );
  }

  /**
   * Stream a PowerShell script over stdin (no command-line length limit).
   * `suffix` is appended after the script block, e.g. "-OneDrive Remove".
   */
  async guestPowerShellStream(script, { suffix = '', ...opts } = {}) {
    const wrapper = [
      '$src=[Console]::In.ReadToEnd()',
      '$sb=[ScriptBlock]::Create($src)',
      `& $sb ${suffix}`,
    ].join('; ');
    const encoded = Buffer.from(wrapper, 'utf16le').toString('base64');
    return this.runGuest(
      ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded],
      { input: String(script), timeoutMs: 300_000, ...opts },
    );
  }

  async hostWriteFile(file, content, { privileged = false, timeoutMs = 120_000 } = {}) {
    if (this.config.dryRun) return this.dryRun(['tee', file], { input: content });
    if (privileged) return this.runHostSudo(['tee', file], { input: content, timeoutMs });
    if (this.config.host) {
      return this.execFile('ssh', [...this.sshArgs(this.config.host), '--', `tee ${shQuote(file)}`], { input: content, timeoutMs });
    }
    await fs.mkdir(path.dirname(file), { recursive: true });
    await fs.writeFile(file, content, 'utf8');
    return { ok: true, code: 0, stdout: '', stderr: '', output: '', command: `write ${file}` };
  }

  async hostReadFile(file, { privileged = false, timeoutMs = 60_000 } = {}) {
    if (this.config.dryRun) return this.dryRun(['cat', file]);
    if (privileged) return this.runHostSudo(['cat', file], { timeoutMs });
    if (this.config.host) {
      return this.execFile('ssh', [...this.sshArgs(this.config.host), '--', `cat ${shQuote(file)}`], { timeoutMs });
    }
    try {
      return { ok: true, code: 0, stdout: await fs.readFile(file, 'utf8'), stderr: '', output: '' };
    } catch (error) {
      return { ok: false, code: 1, stdout: '', stderr: '', output: '', error: error.message };
    }
  }

  async hostExists(file) {
    if (this.config.dryRun) return true;
    const result = await this.runHostShell(`test -e ${shQuote(file)}`);
    return result.ok;
  }

  async hostMkdir(dir, { privileged = false } = {}) {
    const argv = ['mkdir', '-p', dir];
    return privileged ? this.runHostSudo(argv) : this.runHost(argv);
  }

  async hostRemove(file, { privileged = false } = {}) {
    const argv = ['rm', '-f', '--', file];
    return privileged ? this.runHostSudo(argv) : this.runHost(argv);
  }

  async hostCopy(source, target, { privileged = false } = {}) {
    const argv = ['cp', '-a', '--', source, target];
    return privileged ? this.runHostSudo(argv) : this.runHost(argv);
  }

  async download(remotePath, localPath) {
    await fs.mkdir(path.dirname(localPath), { recursive: true });
    if (this.config.dryRun) {
      await fs.writeFile(localPath, `dry-run artifact for ${remotePath}\n`);
      return { ok: true, code: 0, stdout: '', stderr: '', output: '' };
    }
    if (!this.config.host) {
      await fs.copyFile(remotePath, localPath);
      return { ok: true, code: 0, stdout: '', stderr: '', output: '' };
    }
    return this.execFile('scp', [
      '-q',
      '-o',
      'BatchMode=yes',
      '-o',
      `StrictHostKeyChecking=${this.config.strictHostKey}`,
      `${this.config.host}:${remotePath}`,
      localPath,
    ], { timeoutMs: 60 * 60 * 1000 });
  }

  async upload(localPath, remotePath) {
    if (this.config.dryRun) {
      return { ok: true, code: 0, stdout: '', stderr: '', output: '' };
    }
    if (!this.config.host) {
      await fs.mkdir(path.dirname(remotePath), { recursive: true });
      await fs.copyFile(localPath, remotePath);
      return { ok: true, code: 0, stdout: '', stderr: '', output: '' };
    }
    return this.execFile('scp', [
      '-q',
      '-o',
      'BatchMode=yes',
      '-o',
      `StrictHostKeyChecking=${this.config.strictHostKey}`,
      localPath,
      `${this.config.host}:${remotePath}`,
    ], { timeoutMs: 60 * 60 * 1000 });
  }

  async capabilities() {
    if (this._capabilities) return this._capabilities;
    if (this.config.dryRun) {
      this._capabilities = {
        mode: 'dry-run',
        controller: {},
        host: {},
        guest: { powershell: true },
        checkedAt: nowIso(),
      };
      return this._capabilities;
    }

    const localCommands = ['node', 'ssh', 'scp', 'tar', 'qemu-nbd', 'ntfs-3g', 'hivexsh', 'reged', 'virsh', 'nix-build', 'nixos-rebuild', 'docker', 'mountpoint'];
    const controller = {};
    for (const command of localCommands) {
      const result = await this.execFile('sh', ['-lc', `command -v ${shQuote(command)} >/dev/null 2>&1`], { timeoutMs: 5_000 });
      controller[command] = result.ok;
    }

    let host = null;
    if (this.config.host) {
      const script = localCommands.map((command) => `printf '%s=' ${shQuote(command)}; command -v ${shQuote(command)} >/dev/null 2>&1 && echo 1 || echo 0`).join('; ');
      const result = await this.runHostShell(script, { timeoutMs: 15_000 });
      host = {};
      for (const line of result.stdout.split(/\r?\n/)) {
        const [name, value] = line.split('=');
        if (name) host[name] = value === '1';
      }
    }

    this._capabilities = {
      mode: this.config.host ? 'ssh' : 'local',
      controller,
      host,
      guest: { powershell: Boolean(this.config.host) },
      checkedAt: nowIso(),
    };
    return this._capabilities;
  }

  dryRun(argv, opts = {}) {
    const text = `[dry-run] ${redactCommand(argv)}${opts.input ? ` (stdin ${humanBytes(Buffer.byteLength(String(opts.input)))})` : ''}\n`;
    return Promise.resolve({
      ok: true,
      code: 0,
      stdout: text,
      stderr: '',
      output: text,
      dryRun: true,
      argv,
      command: redactCommand(argv),
    });
  }
}