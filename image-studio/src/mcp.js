#!/usr/bin/env node
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';
import { loadConfig } from './config.js';
import { LiveSystem } from './live.js';
import { JobManager } from './jobs.js';
import { OfflineImage } from './offline.js';
import { Runner } from './runner.js';
import { discoverArtifacts, planFromJob, planNixosBuild, planWindowsBuild } from './images.js';
import { exportBundle, importBundle, listBundles } from './bundle.js';
import { profilePresets, validateProfile } from './profiles.js';
import { redact } from './util.js';

const SERVER_NAME = 'image-studio';
const SERVER_VERSION = '0.1.0';

function tool(name, description, inputSchema, handler) {
  return { name, description, inputSchema, handler };
}

function schema(properties = {}, required = []) {
  return { type: 'object', properties, required, additionalProperties: false };
}

function str(description) {
  return { type: 'string', description };
}

function bool(description, default_) {
  return { type: 'boolean', description, default: default_ };
}

function num(description, minimum, maximum, default_) {
  return { type: 'number', description, minimum, maximum, default: default_ };
}



export function createTools(context) {
  const { config, runner, jobs, offline, live } = context;

  return [
    tool('image_studio_info', 'Show Image Studio configuration and runtime mode. Secrets are redacted.', schema(), async () => ({
      version: SERVER_VERSION,
      config: redact({
        host: config.host,
        winHost: config.winHost,
        domain: config.domain,
        disk: config.disk,
        nixosRepo: config.nixosRepo,
        dataDir: config.dataDir,
        dryRun: config.dryRun,
        docker: config.docker,
      }),
      note: 'Set IMAGE_STUDIO_HOST to run host/offline operations over SSH; otherwise they run locally.',
    })),

    tool('system_capabilities', 'Detect controller, host and guest commands (qemu-nbd, hivexsh, virsh, nix-build, node, ssh, docker).', schema(), async () => runner.capabilities()),

    tool('nixos_config_read', 'Read the host configuration.nix (default /etc/nixos/configuration.nix).', schema(), async () => live.nixosReadConfig()),

    tool('nixos_config_write', 'Back up and replace the host configuration.nix. Requires confirm=WRITE.', schema({
      content: str('Full configuration.nix content'),
      confirm: str('Must be WRITE'),
    }, ['content', 'confirm']), async (args) => live.nixosWriteConfig(args)),

    tool('nixos_rebuild', 'Run nixos-rebuild (switch, boot, test, build, dry-build, dry-activate). switch/boot require confirm=REBUILD.', schema({
      action: str('switch | boot | test | build | dry-build | dry-activate'),
      confirm: str('REBUILD for switch/boot'),
    }, ['action']), async (args) => live.nixosRebuild(args)),

    tool('nixos_generations', 'List system generations.', schema(), async () => live.nixosGenerations()),

    tool('nixos_rollback', 'Switch to the previous NixOS generation. Requires confirm=REBUILD.', schema({
      confirm: str('Must be REBUILD'),
    }, ['confirm']), async (args) => live.nixosRollback(args)),

    tool('nixos_ksm_status', 'Read KSM run state, zero-page mode, sharing counters and the ksm-zero-pages unit.', schema(), async () => live.ksmStatus()),

    tool('nixos_bluetooth_status', 'Show BlueZ service state, controllers, paired devices and rfkill state.', schema(), async () => live.bluetoothStatus()),

    tool('nixos_bluetooth_scan', 'Scan for Bluetooth devices for N seconds.', schema({
      seconds: num('Scan duration', 3, 60, 10),
    }), async (args) => live.bluetoothScan(args)),

    tool('nixos_bluetooth_pair', 'Pair/trust/connect a Bluetooth device by MAC. The passkey must be typed on the device. Requires confirm=PAIR.', schema({
      address: str('Bluetooth MAC, e.g. 3C:22:FB:AA:BB:CC'),
      confirm: str('Must be PAIR'),
    }, ['address', 'confirm']), async (args) => live.bluetoothPair(args)),

    tool('host_stats', 'Show host memory, load, KSM counters and QEMU RSS.', schema(), async () => live.hostStats()),

    tool('vm_state', 'Show libvirt domain state and dominfo.', schema({
      domain: str('libvirt domain (default from config)'),
    }), async (args) => live.vmState(args)),

    tool('vm_power', 'Start, shut down or destroy a libvirt domain. Requires confirm=POWER.', schema({
      action: { type: 'string', enum: ['start', 'shutdown', 'destroy'] },
      domain: str('libvirt domain (default from config)'),
      confirm: str('Must be POWER'),
    }, ['action', 'confirm']), async (args) => live.vmPower(args)),

    tool('vm_memory', 'Set persistent guest memory with scripts/vm-memory.sh. Requires confirm=RESIZE.', schema({
      gib: num('Memory in GiB', 4, 64),
      domain: str('libvirt domain (default from config)'),
      confirm: str('Must be RESIZE'),
    }, ['gib', 'confirm']), async (args) => live.vmMemory(args)),

    tool('vm_vcpu', 'Set persistent vCPU count for a libvirt domain. Requires confirm=RESIZE.', schema({
      vcpus: num('vCPU count', 1, 64),
      domain: str('libvirt domain (default from config)'),
      confirm: str('Must be RESIZE'),
    }, ['vcpus', 'confirm']), async (args) => live.vmVcpu(args)),

    tool('win_ssh_exec', 'Run a non-PowerShell command over SSH in the Windows guest. Requires confirm=RUN.', schema({
      argv: { type: 'array', items: { type: 'string' }, description: 'Argument vector, e.g. ["qwinsta"]' },
      confirm: str('Must be RUN'),
    }, ['argv', 'confirm']), async (args) => live.winSshExec(args)),

    tool('win_verify', 'Read Windows memory, sessions, services, auto-logon, RDP limits, AI packages/tasks and startup entries.', schema(), async () => live.winVerify()),

    tool('win_powershell', 'Run an arbitrary PowerShell script in the guest over SSH stdin. Requires confirm=RUN.', schema({
      script: str('PowerShell script body'),
      confirm: str('Must be RUN'),
    }, ['script', 'confirm']), async (args) => live.winPowerShell(args)),

    tool('win_service_set', 'Set a Windows service startup type. Requires confirm=RUN.', schema({
      name: str('Service name'),
      startupType: { type: 'string', enum: ['Automatic', 'Manual', 'Disabled'] },
      confirm: str('Must be RUN'),
    }, ['name', 'startupType', 'confirm']), async (args) => live.winServiceSet(args)),

    tool('win_registry_set', 'Create/set a registry value under HKLM or HKCU. Requires confirm=RUN.', schema({
      key: str('Registry key, e.g. HKLM:\\SOFTWARE\\Policies\\...'),
      name: str('Value name'),
      value: { description: 'Value data' },
      type: { type: 'string', enum: ['String', 'DWord', 'QWord', 'ExpandString'], default: 'String' },
      confirm: str('Must be RUN'),
    }, ['key', 'name', 'value', 'confirm']), async (args) => live.winRegistrySet(args)),

    tool('win_appx_remove', 'Remove one or more AppX packages for all users. Requires confirm=RUN.', schema({
      names: { description: 'Package name or array of names', oneOf: [{ type: 'string' }, { type: 'array', items: { type: 'string' } }] },
      allUsers: bool('Remove for all users', true),
      endOfLife: bool('Create the per-user EndOfLife key first (for NonRemovable system packages)', false),
      confirm: str('Must be RUN'),
    }, ['names', 'confirm']), async (args) => live.winAppxRemove(args)),

    tool('win_task_remove', 'Unregister scheduled tasks by path and/or name. Requires confirm=RUN.', schema({
      taskPath: str('Task path, e.g. \\Microsoft\\Windows\\WindowsAI\\'),
      taskName: str('Task name'),
      confirm: str('Must be RUN'),
    }, ['confirm']), async (args) => live.winTaskRemove(args)),

    tool('win_autologon', 'Enable or disable Windows auto-logon and ForceAutoLogon. Password is never returned. Requires confirm=RUN.', schema({
      enabled: bool('Enable auto-logon'),
      user: str('Default user name'),
      domain: str('Default domain / computer name'),
      password: str('Optional password (not logged or returned)'),
      confirm: str('Must be RUN'),
    }, ['enabled', 'confirm']), async (args) => live.winAutologon(args)),

    tool('win_rdp_limits', 'Set RDP disconnect/idle limits and RDP-friendly multi-session policy. Requires confirm=RUN.', schema({
      disconnectMinutes: num('Disconnected-session logoff in minutes (0 = never)', 0, 1440, 5),
      idleMinutes: num('Idle-session limit in minutes (0 = never)', 0, 1440, 30),
      confirm: str('Must be RUN'),
    }, ['confirm']), async (args) => live.winRdpLimits(args)),

    tool('win_recipe', 'Run a session recipe: trim-stock, trim-memory, disable-ai, disable-gaming, disable-telemetry, disable-search, minimal, printer-off, remove-edge, remove-store. Requires confirm=RUN.', schema({
      recipe: { type: 'string', enum: ['trim-stock', 'trim-memory', 'disable-ai', 'disable-gaming', 'disable-telemetry', 'disable-search', 'minimal', 'printer-off', 'remove-edge', 'remove-store'] },
      confirm: str('Must be RUN'),
    }, ['recipe', 'confirm']), async (args) => live.winRecipe(args)),

    tool('win_run_repo_script', 'Run an allowlisted scripts/windows PowerShell script in the guest. Requires confirm=RUN.', schema({
      script: str('Script file name, e.g. trim-stock.ps1'),
      args: { type: 'array', items: { type: 'string' }, description: 'Script arguments' },
      confirm: str('Must be RUN'),
    }, ['script', 'confirm']), async (args) => live.winRunRepoScript(args)),

    tool('offline_status', 'Report VM state, mount state and offline image configuration.', schema(), async () => offline.status()),

    tool('offline_mount', 'Attach the raw disk with qemu-nbd and mount NTFS. Requires confirm=MOUNT.', schema({
      readOnly: bool('Mount read-only', false),
      force: bool('Allow while the VM is running', false),
      confirm: str('Must be MOUNT'),
    }, ['confirm']), async (args) => offline.mount(args)),

    tool('offline_umount', 'Unmount and detach the offline image. Requires confirm=UMOUNT.', schema({
      confirm: str('Must be UMOUNT'),
    }, ['confirm']), async (args) => offline.umount(args)),

    tool('offline_backup', 'Copy SYSTEM and SOFTWARE hives to the backup directory. Requires confirm=BACKUP.', schema({
      confirm: str('Must be BACKUP'),
    }, ['confirm']), async (args) => offline.backupHives(args)),

    tool('offline_hive_get', 'List values at a registry key inside SYSTEM or SOFTWARE.', schema({
      hive: { type: 'string', enum: ['SYSTEM', 'SOFTWARE', 'SAM', 'SECURITY', 'DEFAULT'] },
      key: str('Registry key, e.g. \\Microsoft\\Windows\\CurrentVersion\\Appx\\...'),
    }, ['hive', 'key']), async (args) => offline.hiveGet(args.hive, args.key)),

    tool('offline_hive_set_dword', 'Set a REG_DWORD in an offline hive via reged. Requires confirm=WRITE.', schema({
      hive: { type: 'string', enum: ['SYSTEM', 'SOFTWARE'] },
      key: str('Registry key'),
      name: str('Value name'),
      value: num('32-bit unsigned value', 0, 4294967295),
      confirm: str('Must be WRITE'),
    }, ['hive', 'key', 'name', 'value', 'confirm']), async (args) => offline.hiveSetDword(args.hive, args.key, args.name, args.value, args)),

    tool('offline_hive_delete_key', 'Delete a registry key from an offline hive. Requires confirm=WRITE.', schema({
      hive: { type: 'string', enum: ['SYSTEM', 'SOFTWARE'] },
      key: str('Registry key'),
      confirm: str('Must be WRITE'),
    }, ['hive', 'key', 'confirm']), async (args) => offline.hiveDeleteKey(args.hive, args.key, args)),

    tool('offline_remove', 'Remove a file or directory below the mounted Windows root. Requires confirm=REMOVE.', schema({
      path: str('Windows-relative path, e.g. Windows/SystemApps/...'),
      confirm: str('Must be REMOVE'),
    }, ['path', 'confirm']), async (args) => offline.removePath(args.path, args)),

    tool('offline_service_set', 'Set an offline service Start value (boot/system/auto/manual/disabled or 0-4). Requires confirm=WRITE.', schema({
      name: str('Service name'),
      start: { description: 'boot | system | auto | manual | disabled | 0-4' },
      confirm: str('Must be WRITE'),
    }, ['name', 'start', 'confirm']), async (args) => offline.serviceSet(args.name, args.start, args)),

    tool('offline_ai_remove', 'Back up hives, remove CoreAI/AIFabric payloads, WinSxS folders, WindowsAI tasks and AppX registration. Requires confirm=AI-REMOVE.', schema({
      confirm: str('Must be AI-REMOVE'),
    }, ['confirm']), async (args) => offline.aiRemove(args)),

    tool('offline_harden', 'Run scripts/windows/offline/apply.sh for search, defender or all. Requires confirm=HARDEN.', schema({
      mode: { type: 'string', enum: ['search', 'defender', 'all'] },
      confirm: str('Must be HARDEN'),
    }, ['mode', 'confirm']), async (args) => offline.harden(args.mode, args)),

    tool('image_profiles', 'List built-in NixOS and Windows image presets and their defaults.', schema(), async () => profilePresets()),

    tool('image_validate', 'Validate and normalize an image profile.', schema({
      kind: { type: 'string', enum: ['nixos', 'windows'] },
      profile: { type: 'object', description: 'Profile fields' },
    }, ['kind', 'profile']), async (args) => validateProfile(args.kind, args.profile)),

    tool('image_build_nixos', 'Start a NixOS ISO build job from a profile.', schema({
      profile: { type: 'object', description: 'NixOS profile fields' },
    }, ['profile']), async (args) => {
      const plan = await planNixosBuild(config, runner, args.profile);
      const job = await jobs.start({ kind: 'nixos', argv: plan.argv, meta: plan.meta, preview: plan.preview });
      return { job, plan: { preview: plan.preview, buildDir: plan.buildDir, artifactGlob: plan.artifactGlob } };
    }),

    tool('image_build_windows', 'Start a Windows 11 ISO build job from a profile.', schema({
      profile: { type: 'object', description: 'Windows profile fields' },
      sourceIso: str('Optional source ISO path on the build host'),
    }, ['profile']), async (args) => {
      const plan = await planWindowsBuild(config, runner, { ...args.profile, sourceIso: args.sourceIso || args.profile.sourceIso });
      const job = await jobs.start({ kind: 'windows', argv: plan.argv, meta: plan.meta, preview: plan.preview });
      return { job, plan: { preview: plan.preview, buildDir: plan.buildDir, artifactPath: plan.artifactPath } };
    }),

    tool('image_job_list', 'List build jobs.', schema(), async () => jobs.list()),

    tool('image_job_status', 'Read one job, its log tail and discovered artifacts.', schema({
      id: str('Job id'),
    }, ['id']), async (args) => {
      const job = await jobs.get(args.id);
      if (!job) throw new Error(`job not found: ${args.id}`);
      let artifacts = [];
      if (job.status === 'succeeded') {
        try { artifacts = await discoverArtifacts(config, runner, planFromJob(job)); } catch { /* ignore */ }
      }
      return { job, artifacts };
    }),

    tool('image_job_cancel', 'Cancel a running job.', schema({
      id: str('Job id'),
    }, ['id']), async (args) => jobs.cancel(args.id)),

    tool('image_bundle_export', 'Package a completed job (profile + artifact + checksums) as a .tar.gz bundle.', schema({
      jobId: str('Completed job id'),
      name: str('Bundle file name, e.g. win11-lab.tar.gz'),
      notes: str('Optional notes'),
    }, ['jobId']), async (args) => {
      const job = await jobs.get(args.jobId);
      if (!job) throw new Error(`job not found: ${args.jobId}`);
      if (job.status !== 'succeeded') throw new Error(`job is ${job.status}; only completed jobs can be exported`);
      const plan = planFromJob(job);
      return exportBundle({
        config,
        runner,
        kind: job.kind,
        profile: job.meta.profile,
        job,
        plan,
        name: args.name,
        notes: args.notes,
      });
    }),

    tool('image_bundle_import', 'Import a .tar.gz bundle and verify artifact checksums.', schema({
      file: str('Absolute path to the bundle on the controller'),
    }, ['file']), async (args) => importBundle({ config, runner, file: args.file })),

    tool('image_bundle_list', 'List exported and imported bundles.', schema(), async () => listBundles({ config })),

    tool('tests_run', 'Run the Image Studio test suite (node --test) and return the output.', schema({
      suite: str('Optional test file, e.g. profiles.test.js'),
    }), async (args) => {
      if (args.suite && !/^[A-Za-z0-9_.-]+\.test\.js$/.test(args.suite)) throw new Error('invalid suite name');
      const result = await runner.execFile(process.execPath, ['--test', ...(args.suite ? [path.join('test', args.suite)] : ['test'])], {
        cwd: config.pkgRoot,
        timeoutMs: 10 * 60 * 1000,
      });
      return { ok: result.ok, exitCode: result.code, output: result.output };
    }),
  ];
}

export async function runMcpServer({ config = loadConfig(), input = process.stdin, output = process.stdout } = {}) {
  const runner = new Runner(config);
  const jobs = new JobManager(config);
  await jobs.init();
  const offline = new OfflineImage(config, runner);
  const live = new LiveSystem(config, runner);
  const tools = createTools({ config, runner, jobs, offline, live });
  const byName = new Map(tools.map((item) => [item.name, item]));

  const send = (message) => output.write(`${JSON.stringify(message)}\n`);
  const reply = (id, result) => send({ jsonrpc: '2.0', id, result });
  const fail = (id, code, message) => send({ jsonrpc: '2.0', id, error: { code, message } });

  const rl = readline.createInterface({ input, crlfDelay: Infinity });
  rl.on('line', async (line) => {
    const text = line.trim();
    if (!text) return;
    let request;
    try {
      request = JSON.parse(text);
    } catch {
      fail(null, -32700, 'parse error');
      return;
    }
    const { id = null, method, params = {} } = request;
    try {
      if (method === 'initialize') {
        reply(id, {
          protocolVersion: params.protocolVersion || '2024-11-05',
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
          instructions: 'Build/import NixOS and Windows images, manage libvirt guests, edit offline Windows images, and run verification recipes.',
        });
        return;
      }
      if (method === 'notifications/initialized' || method?.startsWith('notifications/')) return;
      if (method === 'ping') { reply(id, {}); return; }
      if (method === 'tools/list') {
        reply(id, {
          tools: tools.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
        });
        return;
      }
      if (method === 'resources/list') { reply(id, { resources: [] }); return; }
      if (method === 'prompts/list') { reply(id, { prompts: [] }); return; }
      if (method === 'tools/call') {
        const item = byName.get(params.name);
        if (!item) { fail(id, -32602, `unknown tool: ${params.name}`); return; }
        try {
          const result = await item.handler(params.arguments || {});
          reply(id, {
            content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
            isError: false,
          });
        } catch (error) {
          reply(id, {
            content: [{ type: 'text', text: `Error: ${error.message}` }],
            isError: true,
          });
        }
        return;
      }
      fail(id, -32601, `method not found: ${method}`);
    } catch (error) {
      fail(id, -32603, error.message);
    }
  });

  await new Promise((resolve) => rl.on('close', resolve));
}

function isMain() {
  return process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
}

if (isMain()) {
  runMcpServer().catch((error) => {
    process.stderr.write(`image-studio mcp: ${error.stack || error.message}\n`);
    process.exit(1);
  });
}