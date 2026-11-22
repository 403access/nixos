import path from 'node:path';
import { createHash } from 'node:crypto';
import { parseJsonOutput, psQuote, requireConfirm } from './util.js';

const RDP_KEY = 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services';
const WINLOGON = 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon';

function psBool(value) {
  return value ? '$true' : '$false';
}

function jsonScript(body) {
  return `$ErrorActionPreference='SilentlyContinue'\n$ProgressPreference='SilentlyContinue'\n${body}\n`;
}

function validateScriptArg(arg) {
  const text = String(arg);
  if (!/^-[A-Za-z][A-Za-z0-9]*$/.test(text) && !/^[A-Za-z0-9_./:=+-]{1,128}$/.test(text)) {
    throw new Error(`unsafe script argument: ${text}`);
  }
  return text;
}

function validateTaskPart(value, label, pattern) {
  const text = String(value ?? '');
  if (!pattern.test(text)) throw new Error(`invalid ${label}`);
  return text;
}

export class LiveSystem {
  constructor(config, runner) {
    this.config = config;
    this.runner = runner;
  }

  // ---------- VM / host ----------

  async vmState({ domain = this.config.domain } = {}) {
    const state = await this.runner.runHost(['virsh', '-c', 'qemu:///system', 'domstate', domain], { timeoutMs: 30_000 });
    const info = await this.runner.runHost(['virsh', '-c', 'qemu:///system', 'dominfo', domain], { timeoutMs: 30_000 });
    if (!state.ok || !info.ok) {
      const sudoState = await this.runner.runHostSudo(['virsh', '-c', 'qemu:///system', 'domstate', domain], { timeoutMs: 30_000 });
      const sudoInfo = await this.runner.runHostSudo(['virsh', '-c', 'qemu:///system', 'dominfo', domain], { timeoutMs: 30_000 });
      return { ok: sudoState.ok && sudoInfo.ok, domain, state: sudoState.stdout.trim(), info: sudoInfo.stdout, error: sudoState.output.trim() || sudoInfo.output.trim() };
    }
    return { ok: true, domain, state: state.stdout.trim(), info: info.stdout };
  }

  async vmPower({ action, domain = this.config.domain, confirm } = {}) {
    requireConfirm(confirm, 'POWER');
    if (!['start', 'shutdown', 'destroy'].includes(action)) throw new Error('action must be start, shutdown or destroy');
    const result = await this.runner.runHostSudo(['virsh', '-c', 'qemu:///system', action, domain], { timeoutMs: 180_000 });
    return { ok: result.ok, action, domain, output: result.output };
  }

  async vmMemory({ gib, domain = this.config.domain, confirm } = {}) {
    requireConfirm(confirm, 'RESIZE');
    const value = Number(gib);
    if (!Number.isInteger(value) || value < 4 || value > 64) throw new Error('gib must be an integer between 4 and 64');
    const script = path.posix.join(this.config.nixosRepo, 'scripts/vm-memory.sh');
    const result = await this.runner.runHostSudo(['bash', script, String(value), domain], { timeoutMs: 20 * 60 * 1000 });
    return { ok: result.ok, gib: value, domain, output: result.output };
  }

  async vmVcpu({ vcpus, domain = this.config.domain, confirm } = {}) {
    requireConfirm(confirm, 'RESIZE');
    const value = Number(vcpus);
    if (!Number.isInteger(value) || value < 1 || value > 64) throw new Error('vcpus must be an integer between 1 and 64');
    const max = await this.runner.runHostSudo(
      ['virsh', '-c', 'qemu:///system', 'setvcpus', domain, String(value), '--config', '--maximum'],
      { timeoutMs: 60_000 },
    );
    const current = await this.runner.runHostSudo(
      ['virsh', '-c', 'qemu:///system', 'setvcpus', domain, String(value), '--config'],
      { timeoutMs: 60_000 },
    );
    return { ok: max.ok && current.ok, vcpus: value, domain, output: max.output + current.output };
  }

  async hostStats() {
    const script = [
      'echo "--- meminfo"; grep -E "^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree):" /proc/meminfo',
      'echo "--- load"; uptime',
      'echo "--- ksm"; for f in run use_zero_pages pages_sharing; do printf "%s=" "$f"; cat /sys/kernel/mm/ksm/$f 2>/dev/null || echo missing; done',
      'echo "--- qemu"; ps -eo pid,rss,etime,args= | grep "[q]emu-system-x86_64" | awk \'{printf "pid=%s rss=%.2fGiB etime=%s\\n", $1, $2/1048576, $3}\'',
    ].join('; ');
    const result = await this.runner.runHostShell(script, { timeoutMs: 30_000 });
    return { ok: result.ok, output: result.stdout, error: result.ok ? null : result.output.trim() };
  }

  async winSshExec({ argv, confirm } = {}) {
    requireConfirm(confirm, 'RUN');
    if (!Array.isArray(argv) || !argv.length || argv.length > 32) throw new Error('argv must be an array of 1-32 strings');
    const args = argv.map((item) => String(item));
    if (args.some((item) => item.includes('\0') || item.length > 1024)) throw new Error('invalid argv entry');
    const result = await this.runner.runGuest(args, { timeoutMs: 120_000 });
    return { ok: result.ok, argv: args, output: result.output, exitCode: result.code };
  }

  // ---------- Windows live ----------

  async winVerify({ domain = this.config.domain } = {}) {
    const script = jsonScript(`
$os=Get-CimInstance Win32_OperatingSystem
$cs=Get-CimInstance Win32_ComputerSystem
$w=Get-ItemProperty '${WINLOGON}'
$ts=Get-ItemProperty '${RDP_KEY}'
$procs=@(Get-Process)
$ws=($procs | Measure-Object WorkingSet64 -Sum).Sum
$o=[ordered]@{
  hostname=$env:COMPUTERNAME
  user=$cs.UserName
  bootTime=$os.LastBootUpTime
  memory=[ordered]@{
    totalMiB=[math]::Round($os.TotalVisibleMemorySize/1024,0)
    freeMiB=[math]::Round($os.FreePhysicalMemory/1024,0)
    processes=$procs.Count
    workingSetMiB=[math]::Round($ws/1MB,0)
  }
  autologon=[ordered]@{
    autoAdminLogon=$w.AutoAdminLogon
    userName=$w.DefaultUserName
    domain=$w.DefaultDomainName
    forceAutoLogon=$w.ForceAutoLogon
    passwordPresent=[bool](@($w.PSObject.Properties.Name) -contains 'DefaultPassword')
  }
  rdp=[ordered]@{
    maxDisconnectionTime=$ts.MaxDisconnectionTime
    maxIdleTime=$ts.MaxIdleTime
    fResetBroken=$ts.fResetBroken
    fSingleSessionPerUser=$ts.fSingleSessionPerUser
  }
  services=@(Get-Service DoSvc,UsoSvc,wuauserv,TokenBroker,camsvc,WinHttpAutoProxySvc -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ name=$_.Name; status=$_.Status.ToString(); startType=$_.StartType.ToString() } })
  aiPackages=@(Get-AppxPackage | Where-Object { $_.Name -match 'AIFabric|CoreAI|Copilot' } | ForEach-Object { $_.Name })
  aiTasks=@(Get-ScheduledTask | Where-Object { $_.TaskPath -like '\\Microsoft\\Windows\\WindowsAI\\*' } | ForEach-Object { $_.TaskName })
  aiProcesses=@(Get-Process | Where-Object { $_.ProcessName -match 'AIFabric|CoreAI|Copilot|ClickToDo|Recall' } | ForEach-Object { $_.ProcessName })
  startup=@(Get-CimInstance Win32_StartupCommand | ForEach-Object { [ordered]@{ name=$_.Name; location=$_.Location } })
  oneDrivePresent=(Test-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\\OneDrive'))
  edgePresent=(Test-Path 'C:\\Program Files (x86)\\Microsoft\\Edge')
}
$o | ConvertTo-Json -Depth 6 -Compress
`);
    const result = await this.runner.guestPowerShell(script, { timeoutMs: 120_000 });
    return { ok: result.ok, raw: result.stdout, error: result.ok ? null : result.output.trim(), parsed: safeParse(result.stdout) };
  }

  async winPowerShell({ script, confirm } = {}) {
    requireConfirm(confirm, 'RUN');
    const text = String(script || '');
    if (!text.trim()) throw new Error('script is empty');
    if (text.length > 2_000_000) throw new Error('script is too large');
    const result = await this.runner.guestPowerShellStream(text, { timeoutMs: 30 * 60 * 1000 });
    return { ok: result.ok, output: result.output, exitCode: result.code };
  }

  async winServiceSet({ name, startupType, confirm } = {}) {
    requireConfirm(confirm, 'RUN');
    const service = String(name || '');
    if (!/^[A-Za-z0-9_.-]{1,128}$/.test(service)) throw new Error('invalid service name');
    const type = String(startupType || '');
    if (!['Automatic', 'Manual', 'Disabled'].includes(type)) throw new Error('startupType must be Automatic, Manual or Disabled');
    const result = await this.runner.guestPowerShell(jsonScript(`
try {
  Set-Service -Name ${psQuote(service)} -StartupType ${type} -ErrorAction Stop
  $s=Get-Service -Name ${psQuote(service)}
  [ordered]@{ ok=$true; name=$s.Name; status=$s.Status.ToString(); startType=$s.StartType.ToString() } | ConvertTo-Json -Compress
} catch { [ordered]@{ ok=$false; error=$_.Exception.Message } | ConvertTo-Json -Compress }
`));
    return { ok: result.ok, parsed: safeParse(result.stdout), output: result.output };
  }

  async winRegistrySet({ key, name, value, type = 'String', confirm } = {}) {
    requireConfirm(confirm, 'RUN');
    const regKey = String(key || '');
    if (!/^(HKLM|HKCU):\\/.test(regKey) || /[\0\r\n]/.test(regKey) || regKey.length > 512) throw new Error('key must start with HKLM:\\ or HKCU:\\');
    const valueName = String(name || '');
    if (!/^[A-Za-z0-9_.@-]{1,128}$/.test(valueName)) throw new Error('invalid value name');
    const kind = String(type);
    if (!['String', 'DWord', 'QWord', 'ExpandString'].includes(kind)) throw new Error('type must be String, DWord, QWord or ExpandString');
    const literal = kind === 'DWord' || kind === 'QWord' ? String(Number(value)) : psQuote(value);
    const result = await this.runner.guestPowerShell(jsonScript(`
try {
  if (-not (Test-Path ${psQuote(regKey)})) { New-Item -Path ${psQuote(regKey)} -Force | Out-Null }
  Set-ItemProperty -Path ${psQuote(regKey)} -Name ${psQuote(valueName)} -Value ${literal} -Type ${kind} -ErrorAction Stop
  [ordered]@{ ok=$true; key=${psQuote(regKey)}; name=${psQuote(valueName)} } | ConvertTo-Json -Compress
} catch { [ordered]@{ ok=$false; error=$_.Exception.Message } | ConvertTo-Json -Compress }
`));
    return { ok: result.ok, parsed: safeParse(result.stdout), output: result.output };
  }

  async winAppxRemove({ names, allUsers = true, endOfLife = false, confirm } = {}) {
    requireConfirm(confirm, 'RUN');
    const list = Array.isArray(names) ? names : [names];
    if (!list.length || list.some((name) => !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(String(name)))) {
      throw new Error('names must be package names such as Microsoft.WindowsStore');
    }
    const quoted = list.map((name) => psQuote(name)).join(',');
    const result = await this.runner.guestPowerShell(jsonScript(`
$removed=@(); $missing=@(); $failed=@()
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
foreach ($n in @(${quoted})) {
  $pkgs=@(Get-AppxPackage -Name $n -ErrorAction SilentlyContinue)
  if ($pkgs.Count -eq 0) { $missing += $n; continue }
  foreach ($p in $pkgs) {
    try {
      if (${endOfLife ? '$true' : '$false'}) {
        $eol="HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\EndOfLife\\$sid\\$($p.PackageFullName)"
        New-Item -Path $eol -Force | Out-Null
      }
      ${allUsers ? 'Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop' : 'Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop'}
      $removed += $p.PackageFullName
    } catch { $failed += [ordered]@{ package=$p.PackageFullName; error=$_.Exception.Message } }
  }
}
[ordered]@{ removed=$removed; missing=$missing; failed=$failed } | ConvertTo-Json -Depth 4 -Compress
`), { timeoutMs: 300_000 });
    return { ok: result.ok, parsed: safeParse(result.stdout), output: result.output };
  }

  async winTaskRemove({ taskPath, taskName, confirm } = {}) {
    requireConfirm(confirm, 'RUN');
    const taskPathValue = taskPath ? validateTaskPart(taskPath, 'taskPath', /^\\[A-Za-z0-9\\_. -]*\\$/) : null;
    const taskNameValue = taskName ? validateTaskPart(taskName, 'taskName', /^[A-Za-z0-9_. -]{1,128}$/) : null;
    if (!taskPathValue && !taskNameValue) throw new Error('taskPath or taskName is required');
    const selector = taskPathValue
      ? `Get-ScheduledTask -TaskPath ${psQuote(taskPathValue)}${taskNameValue ? ` -TaskName ${psQuote(taskNameValue)}` : ''}`
      : `Get-ScheduledTask -TaskName ${psQuote(taskNameValue)}`;
    const result = await this.runner.guestPowerShell(jsonScript(`
$removed=@(); $failed=@()
try {
  ${selector} -ErrorAction Stop | ForEach-Object {
    try { Unregister-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName -Confirm:$false -ErrorAction Stop; $removed += ($_.TaskPath + $_.TaskName) }
    catch { $failed += $_.Exception.Message }
  }
} catch { $failed += $_.Exception.Message }
[ordered]@{ removed=$removed; failed=$failed } | ConvertTo-Json -Depth 3 -Compress
`));
    return { ok: result.ok, parsed: safeParse(result.stdout), output: result.output };
  }

  async winAutologon({ enabled, user = 'Windows-PC', domain = 'WINDOWS-VM', password, confirm } = {}) {
    requireConfirm(confirm, 'RUN');
    const passwordLine = password ? `Set-ItemProperty $k -Name DefaultPassword -Value ${psQuote(password)} -Type String` : '';
    const body = enabled
      ? `
Set-ItemProperty $k -Name AutoAdminLogon -Value '1' -Type String
Set-ItemProperty $k -Name DefaultUserName -Value ${psQuote(user)} -Type String
Set-ItemProperty $k -Name DefaultDomainName -Value ${psQuote(domain)} -Type String
Remove-ItemProperty $k -Name ForceAutoLogon -ErrorAction SilentlyContinue
${passwordLine}
`
      : `
Remove-ItemProperty $k -Name AutoAdminLogon,DefaultPassword,ForceAutoLogon -ErrorAction SilentlyContinue
`;
    const result = await this.runner.guestPowerShell(jsonScript(`
$k='${WINLOGON}'
${body}
$w=Get-ItemProperty $k
[ordered]@{
  enabled=${enabled ? '$true' : '$false'}
  autoAdminLogon=$w.AutoAdminLogon
  userName=$w.DefaultUserName
  domain=$w.DefaultDomainName
  forceAutoLogon=$w.ForceAutoLogon
  passwordPresent=[bool](@($w.PSObject.Properties.Name) -contains 'DefaultPassword')
} | ConvertTo-Json -Compress
`));
    return { ok: result.ok, parsed: safeParse(result.stdout), output: result.output };
  }

  async winRdpLimits({ disconnectMinutes = 5, idleMinutes = 30, confirm } = {}) {
    requireConfirm(confirm, 'RUN');
    const disconnect = Math.max(0, Math.min(1440, Number(disconnectMinutes) || 0)) * 60_000;
    const idle = Math.max(0, Math.min(1440, Number(idleMinutes) || 0)) * 60_000;
    const result = await this.runner.guestPowerShell(jsonScript(`
$k='${RDP_KEY}'
if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
Set-ItemProperty $k -Name MaxDisconnectionTime -Value ${disconnect} -Type DWord
Set-ItemProperty $k -Name MaxIdleTime -Value ${idle} -Type DWord
Set-ItemProperty $k -Name fResetBroken -Value 0 -Type DWord
Set-ItemProperty $k -Name fSingleSessionPerUser -Value 0 -Type DWord
$p=Get-ItemProperty $k
[ordered]@{ maxDisconnectionTime=$p.MaxDisconnectionTime; maxIdleTime=$p.MaxIdleTime; fResetBroken=$p.fResetBroken; fSingleSessionPerUser=$p.fSingleSessionPerUser } | ConvertTo-Json -Compress
`));
    return { ok: result.ok, parsed: safeParse(result.stdout), output: result.output };
  }

  async winRunRepoScript({ script, args = [], confirm } = {}) {
    requireConfirm(confirm, 'RUN');
    const allowed = new Set([
      'trim-stock.ps1', 'trim-memory.ps1', 'disable-ai.ps1', 'disable-gaming.ps1',
      'disable-telemetry.ps1', 'minimal.ps1', 'toggle-search.ps1', 'verify-minimal.ps1',
      'optimize-services.ps1', 'apply-explorer-preferences.ps1',
    ]);
    const name = String(script || '');
    if (!allowed.has(name)) throw new Error(`script must be one of: ${[...allowed].join(', ')}`);
    const suffix = (Array.isArray(args) ? args : []).map(validateScriptArg).join(' ');
    const local = path.join(this.config.repoRoot, 'scripts/windows', name);
    const body = await import('node:fs/promises').then((fs) => fs.readFile(local, 'utf8'));
    const result = await this.runner.guestPowerShellStream(body, { suffix, timeoutMs: 30 * 60 * 1000 });
    return { ok: result.ok, script: name, args: suffix, output: result.output };
  }

  async winRecipe({ recipe, confirm } = {}) {
    requireConfirm(confirm, 'RUN');
    const recipes = {
      'trim-stock': ['trim-stock.ps1', ['-OneDrive', 'Remove', '-Apps', 'Lean', '-Services', 'Lean']],
      'trim-memory': ['trim-memory.ps1', ['-DisableSearch', '-DisableSysMain']],
      'disable-ai': ['disable-ai.ps1', []],
      'disable-gaming': ['disable-gaming.ps1', []],
      'disable-telemetry': ['disable-telemetry.ps1', []],
      'minimal': ['minimal.ps1', ['-Mode', 'power', '-StockApps', 'Lean', '-StockServices', 'Balanced', '-EnableSsh', '-SkipCleanup']],
      'disable-search': ['toggle-search.ps1', ['-Disable']],
    };
    if (recipe in recipes) {
      const [script, args] = recipes[recipe];
      return this.winRunRepoScript({ script, args, confirm: 'RUN' });
    }
    if (recipe === 'printer-off') return this.winPrinterOff({ confirm: 'RUN' });
    if (recipe === 'remove-edge') return this.winRemoveEdge({ confirm: 'RUN' });
    if (recipe === 'remove-store') return this.winRemoveStore({ confirm: 'RUN' });
    throw new Error(`unknown recipe: ${recipe}`);
  }

  async winPrinterOff({ confirm } = {}) {
    requireConfirm(confirm, 'RUN');
    const result = await this.runner.guestPowerShell(jsonScript(`
$services=@('Spooler','PrintNotify','PrintScanBrokerService','PrintDeviceConfigurationService')
foreach($s in $services){ Stop-Service $s -Force -ErrorAction SilentlyContinue; Set-Service $s -StartupType Disabled -ErrorAction SilentlyContinue }
Get-Printer -ErrorAction SilentlyContinue | ForEach-Object { Remove-Printer -Name $_.Name -ErrorAction SilentlyContinue }
Get-PrinterDriver -ErrorAction SilentlyContinue | ForEach-Object { Remove-PrinterDriver -Name $_.Name -ErrorAction SilentlyContinue }
Get-PrinterPort -ErrorAction SilentlyContinue | ForEach-Object { Remove-PrinterPort -Name $_.Name -ErrorAction SilentlyContinue }
[ordered]@{ printers=@(Get-Printer -ErrorAction SilentlyContinue).Count; services=@(Get-Service $services -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ name=$_.Name; status=$_.Status.ToString(); startType=$_.StartType.ToString() } }) } | ConvertTo-Json -Depth 4 -Compress
`), { timeoutMs: 180_000 });
    return { ok: result.ok, parsed: safeParse(result.stdout), output: result.output };
  }

  async winRemoveEdge({ confirm } = {}) {
    requireConfirm(confirm, 'RUN');
    const result = await this.runner.guestPowerShell(jsonScript(`
Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-AppxPackage *Edge* -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'Edge' } | ForEach-Object { Unregister-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
$paths=@('C:\\Program Files (x86)\\Microsoft\\Edge','C:\\Program Files\\Microsoft\\Edge')
foreach($p in $paths){ if(Test-Path $p){ takeown.exe /f $p /r /d y | Out-Null; icacls.exe $p /grant '*S-1-5-32-544:F' /t /c | Out-Null; Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } }
$run='HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'; (Get-ItemProperty $run -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -like 'MicrosoftEdgeAutoLaunch*' } | ForEach-Object { Remove-ItemProperty -Path $run -Name $_.Name -ErrorAction SilentlyContinue }
[ordered]@{ appx=@(Get-AppxPackage *Edge* -ErrorAction SilentlyContinue).Count; dirs=@($paths | Where-Object { Test-Path $_ }) } | ConvertTo-Json -Depth 3 -Compress
`), { timeoutMs: 300_000 });
    return { ok: result.ok, parsed: safeParse(result.stdout), output: result.output };
  }

  async winRemoveStore({ confirm } = {}) {
    requireConfirm(confirm, 'RUN');
    const result = await this.runner.guestPowerShell(jsonScript(`
$removed=@(); $failed=@()
foreach($n in @('Microsoft.WindowsStore','Microsoft.StorePurchaseApp')){
  Get-AppxPackage $n -ErrorAction SilentlyContinue | ForEach-Object { try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop; $removed += $_.PackageFullName } catch { $failed += $_.Exception.Message } }
}
$svc=Get-Service InstallService -ErrorAction SilentlyContinue
if($svc){ Stop-Service InstallService -Force -ErrorAction SilentlyContinue; Set-Service InstallService -StartupType Disabled -ErrorAction SilentlyContinue }
Get-ScheduledTask -TaskPath '\\Microsoft\\Windows\\InstallService\\*' -ErrorAction SilentlyContinue | ForEach-Object { Disable-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName -ErrorAction SilentlyContinue | Out-Null }
New-Item 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\WindowsStore' -Force | Out-Null
Set-ItemProperty 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\WindowsStore' -Name RemoveWindowsStore -Value 1 -Type DWord
[ordered]@{ removed=$removed; failed=$failed; installService=(Get-Service InstallService -ErrorAction SilentlyContinue).StartType.ToString() } | ConvertTo-Json -Depth 3 -Compress
`), { timeoutMs: 300_000 });
    return { ok: result.ok, parsed: safeParse(result.stdout), output: result.output };
  }

  // ---------- NixOS live ----------

  get nixosConfigPath() {
    return path.posix.join(this.config.nixosRepo, 'configuration.nix');
  }

  async nixosReadConfig() {
    const result = await this.runner.hostReadFile(this.nixosConfigPath, { privileged: true });
    return { ok: result.ok, path: this.nixosConfigPath, content: result.stdout, error: result.ok ? null : result.output.trim() };
  }

  async nixosWriteConfig({ content, confirm } = {}) {
    requireConfirm(confirm, 'WRITE');
    const text = String(content ?? '');
    if (!text.includes('{') || text.length > 200_000) throw new Error('configuration content looks invalid');
    const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..+$/, '');
    const backup = `/root/configuration.nix.bak-image-studio-${stamp}`;
    const copy = await this.runner.runHostSudo(['cp', '-a', '--', this.nixosConfigPath, backup], { timeoutMs: 60_000 });
    if (!copy.ok) throw new Error(`backup failed: ${copy.output.trim() || copy.error}`);
    const write = await this.runner.hostWriteFile(this.nixosConfigPath, text, { privileged: true });
    if (!write.ok) throw new Error(`write failed: ${write.output.trim() || write.error}`);
    return {
      ok: true,
      path: this.nixosConfigPath,
      backup,
      sha256: createHash('sha256').update(text).digest('hex'),
      bytes: Buffer.byteLength(text),
    };
  }

  async nixosRebuild({ action = 'switch', confirm } = {}) {
    const allowed = ['switch', 'boot', 'test', 'build', 'dry-build', 'dry-activate'];
    if (!allowed.includes(action)) throw new Error(`action must be one of: ${allowed.join(', ')}`);
    if (action === 'switch' || action === 'boot') requireConfirm(confirm, 'REBUILD');
    const result = await this.runner.runHostSudo(['nixos-rebuild', action], { timeoutMs: 60 * 60 * 1000 });
    return { ok: result.ok, action, output: result.output, exitCode: result.code };
  }

  async nixosGenerations() {
    const result = await this.runner.runHostSudo(
      ['nix-env', '--list-generations', '--profile', '/nix/var/nix/profiles/system'],
      { timeoutMs: 60_000 },
    );
    return { ok: result.ok, output: result.stdout, error: result.ok ? null : result.output.trim() };
  }

  async nixosRollback({ confirm } = {}) {
    requireConfirm(confirm, 'REBUILD');
    const result = await this.runner.runHostSudo(['nixos-rebuild', 'switch', '--rollback'], { timeoutMs: 60 * 60 * 1000 });
    return { ok: result.ok, output: result.output };
  }

  async ksmStatus() {
    const script = [
      'printf "run="; cat /sys/kernel/mm/ksm/run 2>/dev/null || echo missing',
      'printf "use_zero_pages="; cat /sys/kernel/mm/ksm/use_zero_pages 2>/dev/null || echo missing',
      'printf "pages_shared="; cat /sys/kernel/mm/ksm/pages_shared 2>/dev/null || echo missing',
      'printf "pages_sharing="; cat /sys/kernel/mm/ksm/pages_sharing 2>/dev/null || echo missing',
      'printf "pages_volatile="; cat /sys/kernel/mm/ksm/pages_volatile 2>/dev/null || echo missing',
      'printf "unit="; systemctl is-enabled ksm-zero-pages.service 2>/dev/null || echo absent',
      'printf "active="; systemctl is-active ksm-zero-pages.service 2>/dev/null || echo inactive',
    ].join('; ');
    const result = await this.runner.runHostShell(script, { timeoutMs: 30_000 });
    return { ok: result.ok, output: result.stdout, error: result.ok ? null : result.output.trim() };
  }

  async bluetoothStatus() {
    const script = [
      'printf "enabled="; systemctl is-enabled bluetooth.service 2>/dev/null || echo absent',
      'printf "active="; systemctl is-active bluetooth.service 2>/dev/null || echo inactive',
      'echo "--- controllers"; bluetoothctl list 2>&1 || true',
      'echo "--- devices"; bluetoothctl devices 2>&1 || true',
      'echo "--- rfkill"; rfkill list 2>&1 || true',
    ].join('; ');
    const result = await this.runner.runHostShell(script, { timeoutMs: 30_000 });
    return { ok: result.ok, output: result.stdout, error: result.ok ? null : result.output.trim() };
  }

  async bluetoothScan({ seconds = 10 } = {}) {
    const wait = Math.max(3, Math.min(60, Number(seconds) || 10));
    const result = await this.runner.runHostSudo(['bluetoothctl', '--timeout', String(wait), 'scan', 'on'], { timeoutMs: (wait + 10) * 1000 });
    return { ok: result.ok, output: result.output };
  }

  async bluetoothPair({ address, confirm } = {}) {
    requireConfirm(confirm, 'PAIR');
    if (!/^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/.test(String(address || ''))) throw new Error('address must be a Bluetooth MAC');
    const commands = [
      'power on',
      'agent on',
      'default-agent',
      `pair ${address}`,
      `trust ${address}`,
      `connect ${address}`,
      `info ${address}`,
      'quit',
    ].join('\n');
    const result = await this.runner.runHostSudo(['bluetoothctl'], { input: `${commands}\n`, timeoutMs: 90_000 });
    return {
      ok: result.ok,
      output: result.output,
      note: 'If a passkey is printed, type it on the Apple keyboard and press Enter. Pairing cannot be fully automated.',
    };
  }
}

function safeParse(text) {
  try { return parseJsonOutput(text); } catch { return null; }
}

export { safeParse };