# Windows 11 VM memory analysis: process inventory and reduction plan

Guest: `win11-stock` — Windows 11 build 26300 (26H1) — snapshot
**2026-11-21 21:04 CET** (uptime 19 h 55 min) — host NixOS 25.05, QEMU
9.2.4, libvirt 11.4.0.

This document started as a **read-only analysis** of the 2026-11-21 baseline.
On 2026-11-22 two low-risk items from the plan were applied: the vCPU count and
the consumer/startup leftovers. The process table below remains the baseline
snapshot; the applied state is recorded separately.

> The password is deliberately not recorded here. Use
> [`../scripts/win-ssh.sh`](../scripts/win-ssh.sh), which jumps through
> `nixos@192.168.178.5` to `Windows-PC@192.168.122.50`.

## Applied changes (2026-11-22)

- **vCPU:** reduced the domain from 6 to 2 vCPUs with
  `virsh setvcpus win11-stock 2 --config` and `--maximum`. The guest now reports
  **2 logical CPUs** (2 sockets × 1 core). No `<topology>` element was added:
  2 sockets are within the Windows 11 Pro limit, so no vCPU is hidden or
  wasted. Host `dominfo` reports `CPU(s): 2`; the 8 GiB allocation was reduced
  to 4 GiB in the memory pass below.
- **Host memory:** reduced the domain from 8 GiB to 4 GiB with the same
  `setmaxmem`/`setmem --config` pair (guest shut down first). QEMU RSS fell from
  **8.10 GiB to 4.10 GiB** before KSM, and to **~2.0 GiB at idle** once KSM
  merged the guest's zero pages. The guest reports **4,076 MiB total, 2,819 MiB
  free**. No balloon device is present, so 4 GiB is a hard cap; RSS rises toward
  it as the guest actually uses memory.
- **RDP session limits:** `MaxDisconnectionTime=300000` (5 min),
  `MaxIdleTime=1800000` (30 min), `fResetBroken=1` and
  `fSingleSessionPerUser=1` under
  `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services`. A closed RDP
  client no longer leaves the full per-user session resident indefinitely.
- **Update stack:** `DoSvc`, `UsoSvc` and `wuauserv` are Disabled. `DoSvc` is
  `LaunchProtected=2`, so it could only be disabled offline (`Start=4` in the
  `SYSTEM` hive); the others were disabled online. The guest is patched to
  KB5132056/KB5132057 before this change. Re-enable for patch day.
- **On-demand services:** `TokenBroker`, `camsvc` and `WinHttpAutoProxySvc` were
  stopped; `TokenBroker` and `camsvc` are Disabled, and the per-user templates
  `PimIndexMaintenanceSvc`, `UnistoreSvc` and `UserDataSvc` are `Start=4`.
  `WinHttpAutoProxySvc` is ACL-protected and stays Manual/on-demand.
- **Leftover cleanup:** removed the OneDrive per-user engine and
  `OneDriveSetup.exe` (664 MB total), deleted the LocalService `OneDriveSetup`
  Run value, removed the dead Edge auto-launch value and the stale Edge/Edge
  Update uninstall keys, unregistered the duplicate
  `\WindowsSlim\StartPowerToys` task (the PowerToys `Autorun` task remains), and
  removed the per-user `SoftLanding` promo task. No OneDrive or Edge startup
  entry is left.
- **KSM:** enabled at runtime (`run=1`, `use_zero_pages=1`). A high-rate test
  (2000 pages/10 ms) completed 74 scans and shared **26,790 non-zero pages**;
  steady state is 500 pages/50 ms, where `pages_sharing` is **31,423 pages ≈
  123 MiB**. Zero-page merging is larger but is **not counted** by
  `pages_sharing`: QEMU RSS dropped from 4.10 GiB to **~2.0 GiB** at idle. The
  setting is runtime-only until it is added to the host config; a host reboot
  loses the zero-page win.
- **Current idle snapshot:** **68 processes**, **1,509 MiB working set**,
  **2,819 MiB free**, **100 services Disabled**. PowerToys Run was warm at
  ~200 MiB during the audit and drops when its UI is idle.
- **Consumer leftovers:** removed the per-user packages
  `MicrosoftWindows.CrossDevice`, `MicrosoftWindows.Client.WebExperience`
  (Widgets), `Microsoft.BingSearch` and `Microsoft.OneDrive.Photos`;
  deprovisioned the first three; removed the Network Service `OneDriveSetup`
  Run value and the Edge auto-launch value; disabled the three OneDrive
  scheduled tasks; set the cross-device policies and the per-user Resume /
  OneDrive Resume values to `0`.
- **CrossDeviceResume backstop:** `sihost` relaunched the process after the
  package removal, so a `\WindowsSlim\Kill CrossDeviceResume` logon task
  (SYSTEM, 3 s delay) now terminates it. The process is currently absent.
- **Search:** `WSearch` was already Disabled/Stopped, but
  `SearchEngine-Client-Package` was still Enabled and `SearchHost.exe` kept
  starting in the RDP session at about **120 MiB**. IFEO was tried first and was
  ignored by packaged-app activation. The aggressive fix that now holds:
  disabled the optional feature; renamed `SearchHost.exe` and
  `SearchProviderHost.exe` to `.disabled` (they are hardlinks into WinSxS, so
  Windows can restore them); and added a permanent WMI process-start consumer
  `WindowsSlim-SearchHost-Start` that kills any `SearchHost.exe`,
  `SearchProviderHost.exe`, `SearchIndexer.exe`, `SearchProtocolHost.exe`,
  `SearchFilterHost.exe` or `SearchApp.exe` immediately on launch. The WMI guard
  was tested with a dummy `SearchHost.exe` and works. After 30 s: no search
  processes, `WSearch` Disabled/Stopped, feature Disabled. Search is fully
  non-functional.
- **Start menu:** `StartMenuExperienceHost.exe` was opening the Win-key tiles
  window at **145.8 MiB**. The binary was renamed to `.disabled` and a permanent
  WMI process-start guard `WindowsSlim-StartMenu-Start` kills it if Windows
  restores it. A Ctrl+Esc test from the RDP session produced no Start process;
  `explorer`, `sihost` and `ShellExperienceHost` kept their original PIDs and
  start times. The taskbar Start button is now inert.
- **Launcher:** Everything was installed first but is a file search tool, not a
  Raycast-style command launcher. It was replaced with **PowerToys Run**
  (PowerToys 0.102.3101, per-user). Every other PowerToys module, including
  CmdPal, is disabled; PowerToys’ own
  `\PowerToys\Autorun for Windows-PC` logon task starts it (3 s delay), and the
  duplicate `\WindowsSlim\StartPowerToys` task was removed. **Alt+Space** opens
  it. It **idles as low as ~17 MiB** (8 MiB
  host + 8 MiB launcher) after a quiet period, typically **~80–105 MiB after
  use**, rises to ~190 MiB after the UI warms, and peaks around ~235 MiB.
  Everything’s service, Run value, shortcuts and folder were removed. See
  section 12.
- **Why PowerToys Run, not Everything/Raycast/CmdPal:** Everything is a search
  window, not a command launcher. Raycast for Windows exists but is
  account/cloud-centric and heavier; CmdPal (PowerToys’ newer successor) was
  measured at 176 MiB plus the 46 MiB host and is less mature. PowerToys Run is
  local, Microsoft-signed, stable, and extensible. At idle it is **far lighter
  than the 145.8 MiB Start menu** (as low as ~17 MiB, 80–105 after use), though
  it costs ~43 MiB more while the UI is warm (~190 MiB). The all-modules default
  was ~740 MiB; trimming to Run is what makes it viable.
- **AI components:** `MicrosoftWindows.Client.CoreAI` and the
  `Microsoft.AIFabric.CBS.1.6` framework were removed online, but CBS restored
  both on the next boot.  A second pass removed them **offline** (package
  folders, five WinSxS components, `WindowsAI` task folder and both
  `InboxApplications` keys), which survived the reboot and passed
  `DISM /CheckHealth`.  `WSAIFabricSvc` is Disabled; all six
  `\Microsoft\Windows\WindowsAI\*` tasks are gone; Copilot/Recall/Click-to-Do,
  Paint, Notepad, Edge and Settings-page policies are set.  No AI
  process/task/service/package remains.  Backups are in
  `C:\ProgramData\WindowsSlim\backup\AIFabric-CBS-1.6` and, on the host,
  `/root/ai-offline-backup-2026-11-22`.  See
  [`windows-ai-removal.md`](windows-ai-removal.md).
- **Not removable per-user:** `Microsoft.Windows.PeopleExperienceHost` and
  `Microsoft.XboxGameCallableUI` are protected system apps; removal returns
  `0x80073CFA`. They are not running and consume no measurable RAM. Removing
  them requires an offline image edit.
- **Post-change snapshots:** after the vCPU and leftover changes, 91 processes,
  1,782 MiB working set, 6,893 MiB free. After the search removal, 84 processes,
  1,477 MiB working set, 7,038 MiB free. After the Start-menu replacement the
  Start host is gone and PowerToys Run idles as low as ~17 MiB (80–105 after use); the exact free figure
  varies with the active RDP session. These are not directly comparable to the
  baseline because Task Manager and the inventory/WMI processes are gone and the
  guest rebooted.

### Printer, features, services and apps (2026-11-22)

- **Printer:** no printers, drivers or ports remain. `Spooler`,
  `PrintNotify`, `PrintScanBrokerService` and `PrintDeviceConfigurationService`
  are Disabled; `Printing-Foundation-Features`,
  `Printing-PrintToPDFServices-Features` and
  `Printing-Foundation-InternetPrinting-Client` are Disabled;
  `PrintWorkflowUserSvc` is template-disabled. `PrintQueueActionCenter` and
  `Windows.PrintDialog` are protected system AppX packages and cannot be removed
  per-user; they are not running.
- **Optional features disabled:** `WorkFolders-Client`, `WCF-Services45`,
  `WCF-TCP-PortSharing45`, `SmbDirect`, `MSRDC-Infrastructure` and
  `Microsoft-RemoteDesktopConnection`. The RDP **server** (`TermService`) is
  untouched; only the guest-side client is gone.
- **Machine services disabled:** `whesvc`, `InventorySvc`, `DsSvc`, `PcaSvc`,
  `NcdAutoSetup`, `DisplayEnhancementService`, `RmSvc`, `DusmSvc`, `TrkWks`,
  `lmhosts`, `iphlpsvc`, `LanmanServer`, `CDPSvc`, `webthreatdefsvc`,
  `ShellHWDetection` and `WSAIFabricSvc`. `RmSvc` is still running until the next
  reboot; `DoSvc` was stopped but its start type is protected and remains Auto.
- **Per-user services disabled:** templates for `WpnUserService`, `CDPUserSvc`,
  `cbdhsvc` and `webthreatdefusersvc` are set to Start=4, and the live instances
  are stopped. `UdkUserSvc` is left alone.
- **Apps removed:** Command Palette, Camera, Sticky Notes, Dev Home and Quick
  Assist. `NarratorQuickStart` and `ParentalControls` are protected system AppX
  packages and remain installed but idle.
- **Browser:** Edge was removed (executable, AppX, update services/tasks,
  shortcuts, live profile), freeing about **480 MiB**; the profile is backed up
  at `C:\ProgramData\WindowsSlim\backup\Edge-UserData`. Chrome is now installed
  and used instead, and the shared WebView2 runtime was retained. See
  [`windows-edge-removal.md`](windows-edge-removal.md).
- **Microsoft Store:** Store and Store Purchase were removed; `InstallService`
  is Disabled with its six tasks; `RemoveWindowsStore=1` is set. Winget
  (`DesktopAppInstaller`/`Winget.Source`) and `ClipSVC`/`LicenseManager` were
  kept. See [`windows-store-removal.md`](windows-store-removal.md).
- **Left alone:** Chrome, FL Studio, SmartScreen (~24 MiB), audio (FL Studio) and
  PowerToys itself. Printing and scanning are the only user-facing loss; the
  removed WCF/WorkFolders/RDP-client features were unused.
- **Counts:** **87 services disabled**, 9 optional features disabled, 5 apps
  removed. The service trim is worth roughly **250–300 MiB** of working set
  (per-user ~100 MiB + machine ~150–200 MiB); the current free figure is masked
  by Edge/FL Studio activity.
- **Next candidates:** Chrome tabs/extensions, Task Manager if left open
  (~136 MiB), media features if unused, `DoSvc`/`RmSvc` after reboot,
  `TokenBroker`/`UdkUserSvc`, and protected AppX only through an offline image.
  A reboot finalizes the feature payloads and per-user service templates.

## Bottom line

- **The host was paying for memory the guest did not use — now capped at 4 GiB.**
  QEMU RSS fell from **8.10 GiB to 4.10 GiB**; with KSM zero-page merging it is
  **~2.0 GiB at idle**. The guest reports 4,076 MiB total, **2,819 MiB free**
  and ~1.24 GiB used; 4 GiB leaves ~2.7 GiB for applications.
- **KSM's zero-page mode is the second big win.** `use_zero_pages=1` lets KSM
  map the guest's free zero pages to the shared zero page. QEMU RSS dropped by
  ~2.1 GiB beyond the cap. The `pages_sharing` counter shows only ~123 MiB of
  non-zero sharing; the zero pages are not counted. Runtime-only for now.
- **Guest-side cleanup is ~110 MB:** update stack (`DoSvc`, `UsoSvc`,
  `wuauserv`), `TokenBroker`, `camsvc`, and the Pim/Unistore/UserData templates
  are disabled; OneDrive and stale Edge leftovers are gone.
- **RDP limits are applied:** disconnected sessions log off after 5 minutes and
  idle sessions after 30. A disconnected session previously stayed resident at
  ~1 GiB; signing out or the timeout releases it.
- The guest is lean: **100 services disabled**, Defender, Search, SysMain,
  telemetry, Spooler, Xbox and VBS off, startup folder empty, and **68
  processes** at idle. Do not expect another gigabyte from process killing.
- **2 vCPUs are configured and used.** The earlier 6-vCPU topology exposed four
  sockets Windows could not use; that is fixed.

### At a glance

| Metric | Baseline (2026-11-20) | Now (2026-11-22) |
| --- | ---: | ---: |
| Guest assigned RAM | 8 GiB | **4 GiB** |
| Guest used at idle | 1.62 GiB committed | ~1.24 GiB |
| Guest working set | 2.81 GiB (2.35 GiB adjusted baseline) | ~1.51 GiB |
| Host QEMU RSS | 8.10 GiB | **4.10 GiB**, or **~2.0 GiB at idle with KSM** |
| Host QEMU RSS with KSM | 8.10 GiB | **~2.0 GiB** (zero pages merged; `pages_sharing` ~123 MiB) |
| Processes | 110 | **68** |
| Disabled services | 71 | **100** |
| vCPUs configured | 6 (2 usable) | **2** |
| Search UI (`SearchHost`) | up to ~120 MiB when started | removed (feature disabled + WMI kill guard) |
| Start menu (`StartMenuExperienceHost`) | ~146 MiB | removed (renamed + WMI kill guard) |
| Launcher | — | PowerToys Run, ~17–200 MiB depending on state (Alt+Space) |
| RDP disconnected session | kept indefinitely | logged off after 5 min |

Measured after the 4 GiB resize and the cleanup pass: **68 processes, 1,509 MiB
working set, 2,819 MiB free**, with the Start/search hosts and AI packages gone.
PowerToys Run idles as low as ~17 MiB, is ~80–105 MiB after use, and was ~200 MiB
while the UI was warm during the audit. The host allocation is **4 GiB**; there
is no balloon, so the guest cannot exceed it. At idle KSM holds QEMU RSS near
**2.0 GiB**; it rises toward 4 GiB as the guest uses memory.

The guest figures overlap: logging off RDP already frees the per-user services,
so do not add every row in the savings table below.

## Method and caveats

Collected in one SSH session with read-only commands. The complete host→guest
command reference, including the process/service/app/task queries, is in
[`windows-vm-inventory-commands.md`](windows-vm-inventory-commands.md).

```powershell
Get-CimInstance Win32_OperatingSystem
Get-CimInstance Win32_PerfRawData_PerfOS_Memory
Get-Process | Select Id,ProcessName,SessionId,WorkingSet64,PrivateMemorySize64,Path
Get-CimInstance Win32_Service | Select Name,ProcessId,State,StartMode
Get-MpComputerStatus
Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard Win32_DeviceGuard
Get-ScheduledTask
```

Host side:

```bash
virsh -c qemu:///system dommemstat win11-stock
virsh -c qemu:///system dominfo win11-stock
ps -o rss= -p <qemu-pid>
```

**Working set is not additive.** Shared DLLs and copy-on-write pages are counted
once per process, so the sum of working sets is larger than the memory the
guest actually owns. The authoritative guest number is **committed bytes
(1.62 GiB)**; working sets are useful for ranking processes.

The snapshot includes the inventory itself: 1 `powershell`, 3 `sshd`, 1
`conhost`, 3 `WmiPrvSE` and 1 `WmiApSrv` — **~232 MiB** of analysis artifacts.
Those rows are marked `†`. A task manager window left open on the RDP session
adds another **123 MiB**. Windows Update was also active during the snapshot
(`BITS` 25.5 MiB + `TiWorker` 24.9 MiB). Excluding the inventory and the update
worker gives an adjusted idle working set of **~2.35 GiB**.

## Live numbers

| Metric | Value |
| --- | ---: |
| Visible RAM | 8,172 MiB |
| Free physical | 6,168 MiB |
| Committed / commit limit | 1.62 GiB / 9.86 GiB |
| Pagefile | 1.9 GiB fixed, peak usage 0 |
| Processes | 110 |
| Sum of working sets | 2,805 MiB |
| Session 0 (services) | 84 processes, 1,533 MiB |
| Session 1 (RDP user) | 20 processes, 1,082 MiB |
| Session 2 (console lock screen) | 6 processes, 191 MiB |
| Host QEMU RSS | 8,498,656 KiB (8.10 GiB) |
| Host total / available RAM | 31.2 GiB / 18.4 GiB |
| Memory compression / page combining | off / off |
| VBS / Device Guard | off |
| Defender | `Not running` (by design) |
| CPUs seen by Windows | 2 logical (2 sockets × 1 core) |
| vCPUs configured in libvirt | 6 |
| Autostart | enabled |

Session 1 is the active RDP session; session 2 is the console sitting at the
lock screen. Both have their own `dwm`, `winlogon`, `csrss`, `fontdrvhost` and
`ctfmon`.

## Process inventory

The tables below are the live snapshot. Roles describe the process, not a
recommendation to kill it; see sections 4–10 for what is actually safe to
remove.

### Top consumers

| PID | Process | Session | Working set MiB | Private MiB | Role |
| ---: | --- | ---: | ---: | ---: | --- |
| 4872 | explorer | 1 | 283.1 | 112.6 | desktop shell |
| 2092 | StartMenuExperienceHost | 1 | 134.3 | 55.4 | Start menu |
| 2304 | Taskmgr | 1 | 122.8 | 50.0 | left open on the RDP session |
| 96 | Registry | 0 | 119.7 | 8.8 | kernel registry cache (not a user process) |
| 1184 | dwm | 1 | 109.5 | 36.3 | desktop compositor (one per session) |
| 2076 | svchost | 0 | 100.4 | 74.7 | service host; see next table |
| 3964 | LogonUI | 2 | 84.8 | 21.7 | console session lock screen |
| 3516 | powershell † | 0 | 79.1 | 64.4 | inventory shell |
| 3768 | ShellExperienceHost | 1 | 69.7 | 12.9 | shell flyouts / action centre |
| 4736 | dwm | 2 | 60.3 | 19.8 | desktop compositor (one per session) |
| 5496 | WmiPrvSE † | 0 | 51.0 | 36.4 | WMI provider (inventory queries) |
| 3740 | sihost | 1 | 47.8 | 6.9 | shell infrastructure |
| 4896 | ShellHost | 1 | 41.6 | 6.5 | shell host |
| 3928 | svchost | 1 | 40.9 | 7.8 | service host; see next table |
| 3608 | WUDFHost | 0 | 39.8 | 3.7 | user-mode driver host (identify device before touching) |
| 5036 | CrossDeviceResume | 1 | 37.9 | 8.3 | Phone Link resume |
| 700 | svchost | 0 | 37.4 | 9.7 | service host; see next table |
| 2644 | ctfmon | 1 | 32.8 | 4.7 | text input / IME |
| 5644 | WmiPrvSE † | 0 | 31.9 | 13.6 | WMI provider (inventory queries) |
| 2208 | svchost | 0 | 31.5 | 7.1 | service host; see next table |
| 972 | lsass | 0 | 30.8 | 7.4 | local security authority |
| 748 | svchost | 0 | 27.2 | 5.8 | service host; see next table |
| 3776 | svchost | 1 | 25.5 | 5.5 | service host; see next table |
| 4604 | svchost | 0 | 25.5 | 8.8 | service host; see next table |
| 3588 | svchost | 0 | 24.9 | 10.7 | service host; see next table |
| 5084 | svchost | 1 | 24.9 | 3.5 | service host; see next table |
| 4588 | TiWorker | 0 | 24.9 | 8.8 | servicing worker (Windows Update) |
| 1296 | svchost | 0 | 24.0 | 4.7 | service host; see next table |
| 4000 | svchost | 0 | 23.6 | 3.3 | service host; see next table |
| 4784 | RuntimeBroker | 1 | 23.3 | 3.0 | UWP broker |
| 3128 | svchost | 0 | 22.9 | 8.9 | service host; see next table |
| 1928 | svchost | 0 | 22.6 | 14.8 | service host; see next table |
| 832 | svchost | 0 | 21.6 | 8.0 | service host; see next table |
| 4772 | svchost | 0 | 21.1 | 4.3 | service host; see next table |
| 3176 | svchost | 0 | 20.8 | 23.1 | service host; see next table |

### Who is inside `svchost`

| PID | Working set MiB | Services in this host |
| ---: | ---: | --- |
| 2076 | 100.4 | TermService |
| 3928 | 40.9 | WpnUserService_321f3 |
| 700 | 37.4 | BrokerInfrastructure, DcomLaunch, PlugPlay, Power, SystemEventsBroker |
| 2208 | 31.5 | InstallService |
| 972 | 30.8 | KeyIso, SamSs, VaultSvc |
| 748 | 27.2 | DoSvc |
| 4604 | 25.5 | BITS |
| 3776 | 25.5 | CDPUserSvc_321f3 |
| 3588 | 24.9 | Winmgmt |
| 5084 | 24.9 | cbdhsvc_321f3 |
| 1296 | 24.0 | CryptSvc |
| 4000 | 23.6 | LicenseManager |
| 3128 | 22.9 | BFE, mpssvc |
| 1928 | 22.6 | EventLog |
| 832 | 21.6 | whesvc |
| 4772 | 21.1 | CDPSvc |
| 3176 | 20.8 | AppXSvc |
| 3972 | 20.4 | TokenBroker |
| 1788 | 19.6 | netprofm |
| 2388 | 19.4 | Audiosrv |
| 3264 | 19.2 | ShellHWDetection |
| 1304 | 18.2 | StateRepository |

### Full process list

<details>
<summary>All 110 processes in the snapshot (2026-11-21 21:04 CET)</summary>

| PID | Process | Session | Working set MiB | Private MiB | Path |
| ---: | --- | ---: | ---: | ---: | --- |
| 4872 | explorer | 1 | 283.1 | 112.6 | `C:\WINDOWS\Explorer.EXE` |
| 2092 | StartMenuExperienceHost | 1 | 134.3 | 55.4 | `C:\Windows\SystemApps\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\StartMenuExperienceHost.exe` |
| 2304 | Taskmgr | 1 | 122.8 | 50.0 | `C:\WINDOWS\system32\taskmgr.exe` |
| 96 | Registry | 0 | 119.7 | 8.8 | `—` |
| 1184 | dwm | 1 | 109.5 | 36.3 | `C:\WINDOWS\system32\dwm.exe` |
| 2076 | svchost | 0 | 100.4 | 74.7 | `C:\WINDOWS\System32\svchost.exe` |
| 3964 | LogonUI | 2 | 84.8 | 21.7 | `C:\WINDOWS\system32\LogonUI.exe` |
| 3516 | powershell † | 0 | 79.1 | 64.4 | `c:\windows\system32\windowspowershell\v1.0\powershell.exe` |
| 3768 | ShellExperienceHost | 1 | 69.7 | 12.9 | `C:\WINDOWS\SystemApps\ShellExperienceHost_cw5n1h2txyewy\ShellExperienceHost.exe` |
| 4736 | dwm | 2 | 60.3 | 19.8 | `C:\WINDOWS\system32\dwm.exe` |
| 5496 | WmiPrvSE † | 0 | 51.0 | 36.4 | `C:\WINDOWS\system32\wbem\wmiprvse.exe` |
| 3740 | sihost | 1 | 47.8 | 6.9 | `C:\WINDOWS\system32\sihost.exe` |
| 4896 | ShellHost | 1 | 41.6 | 6.5 | `C:\Windows\System32\ShellHost.exe` |
| 3928 | svchost | 1 | 40.9 | 7.8 | `C:\WINDOWS\system32\svchost.exe` |
| 3608 | WUDFHost | 0 | 39.8 | 3.7 | `C:\Windows\System32\WUDFHost.exe` |
| 5036 | CrossDeviceResume | 1 | 37.9 | 8.3 | `C:\WINDOWS\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\CrossDeviceResume.exe` |
| 700 | svchost | 0 | 37.4 | 9.7 | `C:\WINDOWS\system32\svchost.exe` |
| 2644 | ctfmon | 1 | 32.8 | 4.7 | `C:\WINDOWS\system32\ctfmon.exe` |
| 5644 | WmiPrvSE † | 0 | 31.9 | 13.6 | `C:\WINDOWS\system32\wbem\wmiprvse.exe` |
| 2208 | svchost | 0 | 31.5 | 7.1 | `C:\WINDOWS\System32\svchost.exe` |
| 972 | lsass | 0 | 30.8 | 7.4 | `—` |
| 748 | svchost | 0 | 27.2 | 5.8 | `—` |
| 3776 | svchost | 1 | 25.5 | 5.5 | `C:\WINDOWS\system32\svchost.exe` |
| 4604 | svchost | 0 | 25.5 | 8.8 | `C:\WINDOWS\System32\svchost.exe` |
| 3588 | svchost | 0 | 24.9 | 10.7 | `C:\WINDOWS\system32\svchost.exe` |
| 5084 | svchost | 1 | 24.9 | 3.5 | `C:\WINDOWS\system32\svchost.exe` |
| 4588 | TiWorker | 0 | 24.9 | 8.8 | `C:\WINDOWS\winsxs\amd64_microsoft-windows-servicingstack_31bf3856ad364e35_10.0.26100.9971_none_a4f22b5b777377f6\TiWorker.exe` |
| 1296 | svchost | 0 | 24.0 | 4.7 | `C:\WINDOWS\system32\svchost.exe` |
| 4000 | svchost | 0 | 23.6 | 3.3 | `C:\WINDOWS\System32\svchost.exe` |
| 4784 | RuntimeBroker | 1 | 23.3 | 3.0 | `C:\Windows\System32\RuntimeBroker.exe` |
| 3128 | svchost | 0 | 22.9 | 8.9 | `C:\WINDOWS\system32\svchost.exe` |
| 1928 | svchost | 0 | 22.6 | 14.8 | `C:\WINDOWS\System32\svchost.exe` |
| 832 | svchost | 0 | 21.6 | 8.0 | `C:\WINDOWS\system32\svchost.exe` |
| 4772 | svchost | 0 | 21.1 | 4.3 | `C:\WINDOWS\system32\svchost.exe` |
| 3176 | svchost | 0 | 20.8 | 23.1 | `—` |
| 3972 | svchost | 0 | 20.4 | 3.2 | `C:\WINDOWS\system32\svchost.exe` |
| 1788 | svchost | 0 | 19.6 | 4.5 | `C:\WINDOWS\System32\svchost.exe` |
| 1292 | ctfmon | 2 | 19.5 | 2.9 | `C:\WINDOWS\system32\ctfmon.exe` |
| 2388 | svchost | 0 | 19.4 | 3.3 | `C:\WINDOWS\System32\svchost.exe` |
| 4044 | taskhostw | 1 | 19.3 | 2.8 | `C:\WINDOWS\system32\taskhostw.exe` |
| 3264 | svchost | 0 | 19.2 | 2.6 | `C:\WINDOWS\System32\svchost.exe` |
| 1304 | svchost | 0 | 18.2 | 6.2 | `C:\WINDOWS\system32\svchost.exe` |
| 876 | winlogon | 1 | 17.7 | 2.6 | `C:\WINDOWS\system32\winlogon.exe` |
| 3088 | svchost | 0 | 17.6 | 3.0 | `C:\WINDOWS\system32\svchost.exe` |
| 4884 | WmiPrvSE † | 0 | 17.6 | 7.9 | `C:\WINDOWS\system32\wbem\wmiprvse.exe` |
| 1572 | svchost | 0 | 16.9 | 5.8 | `C:\WINDOWS\system32\svchost.exe` |
| 5756 | svchost | 0 | 16.6 | 3.3 | `C:\WINDOWS\system32\svchost.exe` |
| 1056 | svchost | 0 | 16.1 | 5.5 | `C:\WINDOWS\system32\svchost.exe` |
| 5280 | svchost | 0 | 15.6 | 2.6 | `C:\WINDOWS\System32\svchost.exe` |
| 1112 | svchost | 0 | 15.5 | 3.0 | `C:\WINDOWS\System32\svchost.exe` |
| 5580 | rdpclip | 1 | 15.3 | 2.8 | `C:\WINDOWS\System32\rdpclip.exe` |
| 1448 | svchost | 0 | 15.3 | 2.0 | `C:\WINDOWS\system32\svchost.exe` |
| 4080 | svchost | 0 | 14.9 | 3.7 | `C:\WINDOWS\system32\svchost.exe` |
| 1652 | svchost | 0 | 14.6 | 2.7 | `C:\WINDOWS\system32\svchost.exe` |
| 1116 | svchost | 0 | 14.5 | 2.9 | `C:\WINDOWS\system32\svchost.exe` |
| 2864 | svchost | 0 | 14.4 | 6.4 | `C:\WINDOWS\System32\svchost.exe` |
| 592 | svchost | 0 | 13.9 | 3.1 | `C:\WINDOWS\system32\svchost.exe` |
| 1456 | winlogon | 2 | 13.6 | 2.4 | `C:\WINDOWS\system32\winlogon.exe` |
| 3200 | svchost | 0 | 13.5 | 1.9 | `C:\WINDOWS\system32\svchost.exe` |
| 1372 | svchost | 0 | 13.4 | 2.5 | `C:\WINDOWS\System32\svchost.exe` |
| 1824 | svchost | 0 | 13.3 | 2.5 | `C:\WINDOWS\system32\svchost.exe` |
| 3100 | svchost | 0 | 13.3 | 2.3 | `C:\WINDOWS\system32\svchost.exe` |
| 3080 | svchost | 0 | 13.0 | 2.2 | `C:\WINDOWS\System32\svchost.exe` |
| 5928 | svchost | 0 | 13.0 | 3.1 | `C:\WINDOWS\system32\svchost.exe` |
| 4136 | svchost | 0 | 12.5 | 2.4 | `C:\WINDOWS\system32\svchost.exe` |
| 2252 | svchost | 0 | 12.3 | 2.0 | `C:\WINDOWS\System32\svchost.exe` |
| 3336 | svchost | 0 | 12.1 | 2.3 | `C:\WINDOWS\System32\svchost.exe` |
| 2156 | svchost | 0 | 11.6 | 1.9 | `C:\WINDOWS\system32\svchost.exe` |
| 2548 | svchost | 0 | 11.6 | 1.9 | `C:\WINDOWS\System32\svchost.exe` |
| 2788 | svchost | 0 | 11.6 | 2.4 | `C:\WINDOWS\system32\svchost.exe` |
| 5392 | WmiApSrv † | 0 | 11.6 | 1.9 | `C:\WINDOWS\system32\wbem\WmiApSrv.exe` |
| 952 | services | 0 | 11.5 | 4.4 | `—` |
| 2164 | svchost | 0 | 11.5 | 2.8 | `C:\WINDOWS\system32\svchost.exe` |
| 2596 | svchost | 0 | 11.1 | 2.3 | `C:\WINDOWS\System32\svchost.exe` |
| 2408 | svchost | 0 | 11.0 | 1.9 | `C:\WINDOWS\System32\svchost.exe` |
| 3832 | svchost | 1 | 10.9 | 2.0 | `C:\WINDOWS\system32\svchost.exe` |
| 2300 | sshd † | 0 | 10.8 | 2.8 | `C:\WINDOWS\System32\OpenSSH\sshd.exe` |
| 1976 | svchost | 0 | 10.7 | 2.0 | `C:\WINDOWS\system32\svchost.exe` |
| 2444 | svchost | 0 | 10.7 | 2.1 | `C:\WINDOWS\system32\svchost.exe` |
| 2908 | svchost | 0 | 10.6 | 1.9 | `C:\WINDOWS\System32\svchost.exe` |
| 5376 | svchost | 1 | 10.6 | 1.6 | `C:\WINDOWS\system32\svchost.exe` |
| 5416 | sshd † | 0 | 10.5 | 2.7 | `C:\WINDOWS\System32\OpenSSH\sshd.exe` |
| 4200 | svchost | 0 | 10.4 | 1.7 | `C:\WINDOWS\system32\svchost.exe` |
| 812 | wininit | 0 | 10.2 | 1.7 | `—` |
| 436 | sshd † | 0 | 10.1 | 2.3 | `C:\WINDOWS\System32\OpenSSH\sshd.exe` |
| 2812 | svchost | 0 | 10.1 | 1.7 | `C:\WINDOWS\system32\svchost.exe` |
| 1524 | svchost | 0 | 10.0 | 1.8 | `—` |
| 2272 | svchost | 0 | 9.9 | 1.9 | `C:\WINDOWS\system32\svchost.exe` |
| 1140 | conhost † | 0 | 9.8 | 1.6 | `C:\WINDOWS\system32\conhost.exe` |
| 1948 | TrustedInstaller | 0 | 9.7 | 1.6 | `C:\WINDOWS\servicing\TrustedInstaller.exe` |
| 1692 | svchost | 0 | 9.6 | 1.5 | `C:\WINDOWS\system32\svchost.exe` |
| 4356 | svchost | 0 | 9.6 | 1.7 | `C:\WINDOWS\system32\svchost.exe` |
| 1700 | svchost | 0 | 9.1 | 3.1 | `C:\WINDOWS\system32\svchost.exe` |
| 3752 | svchost | 0 | 8.9 | 1.5 | `C:\WINDOWS\system32\svchost.exe` |
| 2744 | svchost | 0 | 8.5 | 1.5 | `C:\WINDOWS\System32\svchost.exe` |
| 1392 | svchost | 0 | 8.4 | 1.7 | `C:\WINDOWS\system32\svchost.exe` |
| 1984 | svchost | 0 | 7.9 | 1.4 | `C:\WINDOWS\System32\svchost.exe` |
| 820 | csrss | 1 | 7.7 | 1.9 | `—` |
| 4924 | csrss | 2 | 7.7 | 1.8 | `—` |
| 4180 | svchost | 0 | 7.6 | 1.3 | `C:\WINDOWS\System32\svchost.exe` |
| 740 | csrss | 0 | 7.5 | 2.0 | `—` |
| 1348 | svchost | 0 | 7.4 | 1.4 | `C:\WINDOWS\System32\svchost.exe` |
| 3984 | dasHost | 0 | 7.1 | 1.2 | `C:\WINDOWS\system32\dashost.exe` |
| 804 | fontdrvhost | 1 | 6.6 | 1.8 | `C:\WINDOWS\system32\fontdrvhost.exe` |
| 4 | System | 0 | 6.1 | 0.1 | `—` |
| 4704 | MicrosoftEdgeUpdate | 0 | 5.8 | 2.9 | `C:\Program Files (x86)\Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe` |
| 2796 | fontdrvhost | 2 | 5.5 | 1.3 | `C:\WINDOWS\system32\fontdrvhost.exe` |
| 656 | fontdrvhost | 0 | 5.3 | 1.4 | `C:\WINDOWS\system32\fontdrvhost.exe` |
| 496 | smss | 0 | 1.8 | 1.1 | `—` |
| 0 | Idle | 0 | 0.0 | 0.1 | `—` |

</details>

† Inventory artifact: the SSH/WMI processes created by this read-only analysis session. They are not part of the idle baseline.

## What is already right

Do not “optimise” these again; they are already in the lean state:

- 71 services disabled, including `SysMain`, `WSearch`, `DiagTrack`,
  `dmwappushservice`, `Spooler`, `RemoteRegistry`, `WalletService`,
  `RetailDemo`, `MapsBroker`, `WMPNetworkSvc`, all Xbox services, `WpnService`,
  `Sense`, `WdNisSvc`, `WerSvc`, `WlanSvc`, `bthserv` and `SCardSvr`.
- Defender is off (`AMRunningMode: Not running`), Web Threat Defense is the only
  remaining Defender-adjacent service.
- Windows Search is fully off: `WSearch` is Disabled/Stopped,
  `SearchEngine-Client-Package` is Disabled, the search binaries are renamed,
  and a WMI process-start consumer kills any search process that tries to
  launch. Start-menu search is intentionally unavailable.
- VBS / Core Isolation is off (`VirtualizationBasedSecurityStatus: 0`).
- Visual effects are already set to **best performance**
  (`VisualFXSetting = 2`).
- No browser, Office app, Teams, OneDrive or third-party background process is
  running. Edge is installed but not resident.
- Startup folders are empty; the `HKCU` and Network Service `Run` keys are
  empty after the 2026-11-22 cleanup.
- The pagefile is fixed at 1.9 GiB and has never been used (`PeakUsage: 0`).
- The guest idled at 1.48 GiB working set / 7.0 GiB free after the applied
  cleanup and search removal — genuinely low for Windows 11.

## Recommendations

Ordered by saved RAM per unit of risk. The *How* commands are for the NixOS
host unless marked **guest**. Guest commands need an elevated PowerShell.

### 1. Cut the host allocation from 8 GiB to 4 GiB — applied, saves ~3.7 GiB

**Applied 2026-11-22.** `dominfo` reports 4,194,304 KiB maximum and current;
QEMU RSS is **4.10 GiB before KSM** and **~2.0 GiB at idle with zero-page
merging**, while the guest shows **4,076 MiB total / 2,819 MiB free**.

**Why.** The guest commits 1.62 GiB and has 6.0 GiB free. The host is holding
8.10 GiB RSS for that. This is the only change that saves multiple gigabytes
without touching Windows.

**How (simple, no driver required):**

```bash
cd ~/Desktop/nixos
sudo ./scripts/vm-memory.sh 4 win11-stock
```

The script gracefully shuts the guest down, sets both maximum and current
memory to 4 GiB, and starts it again. Save RDP work first. Verify:

```bash
virsh -c qemu:///system dominfo win11-stock | grep -E 'Max memory|Used memory'
virsh -c qemu:///system dommemstat win11-stock
./scripts/vm-stats.sh win11-stock
```

`dommemstat` should report `rss` around 4.4–4.6 GiB. The guest will show ~4 GiB
total and ~2.2 GiB free. Measured here: **4.10 GiB RSS before KSM, ~2.0 GiB with
zero-page merging, 2,819 MiB free**.

**Trade-off.** 4 GiB is comfortable for RDP, Office, a browser with a moderate
number of tabs, and SSH. It is not enough for heavy local builds or many
browser profiles. Use 6 GiB as a compromise if that workload is expected, or
the elastic variant below. The current guest uses ~1.24 GiB at idle, so 4 GiB
leaves ~2.7 GiB for Chrome and FL Studio.

> **Do not set `memory=8G` + `currentMemory=4G` without a balloon driver.**
> libvirt boots the guest with the maximum and asks the balloon to reserve the
> difference. If the driver is absent, the request is ignored, the guest keeps
> 8 GiB, and the host RSS does not fall.

**Elastic variant (4 GiB at rest, can grow to 8 GiB):** add the balloon device
first, install the driver while the device is visible, then lower
`currentMemory`. The host has virtio-win 0.1.271 in the Nix store:

```text
/nix/store/d54m268jjz2bdczb13z3pdh46mk2snwn-virtio-win-0.1.271-1/Balloon/w11/amd64
```

The hash changes on updates; resolve it with
`ls -d /nix/store/*-virtio-win-*/Balloon/w11/amd64`. The host already exports
`/` read-write as `\\192.168.122.1\root` (see [`../SECURITY.md`](../SECURITY.md)),
so the guest can mount that share instead of copying the driver.

1. Shut down, then `virsh edit win11-stock` and add the device without changing
   the amount of RAM yet:

   ```xml
   <memory unit='GiB'>8</memory>
   <currentMemory unit='GiB'>8</currentMemory>
   ...
   <memballoon model='virtio'>
     <stats period='10'/>
   </memballoon>
   ```

2. Start the guest. Device Manager shows an unknown **VirtIO Balloon** device.
   Install the driver as Administrator:

   ```powershell
   net use Z: \\192.168.122.1\root /user:nixos
   xcopy /E /I Z:\nix\store\d54m268jjz2bdczb13z3pdh46mk2snwn-virtio-win-0.1.271-1\Balloon\w11\amd64 C:\Temp\balloon
   pnputil /add-driver C:\Temp\balloon\balloon.inf /install
   ```

   Reboot if Windows asks. Confirm the device is no longer unknown
   (`Get-PnpDevice | Where-Object FriendlyName -match Balloon`).

3. Shut down again and set only the current memory:

   ```xml
   <currentMemory unit='GiB'>4</currentMemory>
   ```

4. Start and verify that the balloon is active. `virsh dommemstat` must show
   `actual` (not only `rss`). Then test elasticity:

   ```bash
   virsh -c qemu:///system setmem win11-stock 6G --live
   virsh -c qemu:///system setmem win11-stock 4G --live
   ```

**Do not expect free-page reporting to help.** The Windows virtio-balloon
driver does not implement free-page reporting yet
([virtio-win#899](https://github.com/virtio-win/kvm-guest-drivers-windows/issues/899),
still open in 2026). The host can only reclaim memory that the guest balloon
actually inflates.

### 2. Enable KSM on the host — applied at runtime, ~2.0 GiB idle RSS

**Measured 2026-11-22.** KSM was enabled with `run=1` and `use_zero_pages=1`.
At the default 100 pages/20 ms it did not finish a scan in ten minutes. A
high-rate test (2000 pages/10 ms) completed 74 scans; steady state is 500
pages/50 ms with `pages_sharing` at **31,423 pages ≈ 123 MiB** of *non-zero*
sharing. The zero-page mode is the larger effect: QEMU RSS fell from 4.10 GiB
to **~2.0 GiB** at idle. These zero pages are not included in `pages_sharing`.
The setting is runtime-only for now (see the host unit note below).

**Why.** KSM was off (`/sys/kernel/mm/ksm/run = 0`). Windows zeroes pages when it
frees them, and an idle guest contains many identical zero pages. KSM can map
those to a single physical page, reducing host RSS without shrinking the guest
or installing a driver. The domain has no `<nosharepages/>`, so QEMU marks the
guest RAM mergeable.

**How (runtime only so far).**

```bash
sudo sh -c 'echo 1 > /sys/kernel/mm/ksm/run
            echo 1 > /sys/kernel/mm/ksm/use_zero_pages
            echo 500 > /sys/kernel/mm/ksm/pages_to_scan
            echo 50 > /sys/kernel/mm/ksm/sleep_millisecs'
```

To persist it, add a unit to the host config and rebuild. `/etc/systemd/system`
is read-only on NixOS, so an imperative unit does not survive:

```nix
systemd.services.ksm-zero-pages = {
  description = "Enable KSM zero-page merging for the Windows VM";
  wantedBy = [ "multi-user.target" ];
  after = [ "local-fs.target" ];
  serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
  script = ''
    echo 1 > /sys/kernel/mm/ksm/run
    echo 1 > /sys/kernel/mm/ksm/use_zero_pages
    echo 500 > /sys/kernel/mm/ksm/pages_to_scan
    echo 50 > /sys/kernel/mm/ksm/sleep_millisecs
  '';
};
```

```bash
sudo nixos-rebuild switch
```

Measure after a few minutes:

```bash
cat /sys/kernel/mm/ksm/run
grep -E 'pages_shared|pages_sharing|pages_unshared|pages_volatile' \
  /sys/kernel/mm/ksm/*
# non-zero bytes saved = (pages_sharing - pages_shared) * 4096
# zero-page savings are not counted; compare host QEMU RSS instead
```

**Trade-off.** KSM spends host CPU scanning; 50 ms sleep keeps it modest
(`ksmd` showed 0.0% average CPU). It also has known side-channel
considerations, acceptable for a single-user local VM. With 4 GiB the win is
mostly the zero-page merge (~2 GiB of host RSS at idle); non-zero sharing is
only ~123 MiB.

### 3. Log off disconnected RDP sessions — applied, saves ~1.0 GiB while idle

**Applied 2026-11-22** via Group Policy values (5 min disconnected, 30 min
idle, single session per user):

```powershell
$k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
Set-ItemProperty $k -Name MaxDisconnectionTime -Value 300000 -Type DWord  # 5 min
Set-ItemProperty $k -Name MaxIdleTime          -Value 1800000 -Type DWord # 30 min
Set-ItemProperty $k -Name fResetBroken         -Value 1 -Type DWord
Set-ItemProperty $k -Name fSingleSessionPerUser -Value 1 -Type DWord
```

The per-connection equivalent under
`HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp`
is still available via `tsconfig.msc`; roll back with `0`.

**Why.** `MaxDisconnectionTime` and `MaxIdleTime` were both `0` (never). If the
RDP client closes without signing out, session 1 — Explorer, Start menu, shell
hosts, `dwm`, per-user services — stays resident indefinitely. That session was
**1,082 MiB** in the snapshot.

**Trade-off.** Unsaved work in the disconnected session is lost. Only enable
this if the VM is a workstation, not a place where long-running apps must
survive a disconnect. When logged off, the console lock screen (~191 MiB)
remains.

### 4. Close Task Manager and do not leave it open — saves ~123 MiB

**Why.** `Taskmgr` has been running since 20:38 on the RDP session, consuming
122.8 MiB and polling performance counters. It is not needed for normal use.

**How (guest):**

```powershell
Stop-Process -Name Taskmgr -Force
```

Add this to the “before you disconnect” checklist, or to
`verify-minimal.ps1` as a warning.

### 5. Disable per-user services that this VM does not need — saves ~100 MiB

**Why.** These per-user instances run in session 1 and are easy to miss:
`WpnUserService` 40.9, `CDPUserSvc` 25.5, `cbdhsvc` 24.9,
`webthreatdefusersvc` 10.9 MiB. They provide notifications, nearby sharing,
clipboard history and per-user web threat defense. None is required for RDP,
Office or a browser.

**How (guest, elevated):**

```powershell
$svcs = 'WpnUserService','CDPUserSvc','cbdhsvc','webthreatdefusersvc'
foreach ($s in $svcs) {
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$s" -Name Start -Value 4 -Type DWord
}
# Stop the live instances now; the template value governs the next logon.
Get-Service 'WpnUserService_*','CDPUserSvc_*','cbdhsvc_*','webthreatdefusersvc_*' `
  -ErrorAction SilentlyContinue |
  Stop-Service -Force -ErrorAction SilentlyContinue
```

**Trade-off.** No toast notifications, no Win+V clipboard history/emoji panel,
no Phone Link nearby sharing. Basic clipboard redirection (`rdpclip`) still
works. Leave `UdkUserSvc` alone; the shell user-data stack is not worth the
risk for 10 MiB.

### 6. Disable optional machine services — saves ~170–300 MiB

**Why.** These services each own a `svchost` host and are not needed for the
documented role. The measured working set is per host, so the saving is close
to the listed number when the service is alone.

| Service | MiB | Verdict | What stops working |
| --- | ---: | --- | --- |
| `whesvc` | 21.6 | Disable | Windows Health and Optimized Experiences (new 2025 background optimiser) |
| `InventorySvc` | 11.6 | Disable | compatibility/inventory appraisal |
| `DsSvc` | 14.4 | Disable | UWP file pickers that use data sharing |
| `PcaSvc` | 13.9 | Disable | Program Compatibility Assistant prompts |
| `NcdAutoSetup` | 13.0 | Disable | automatic setup of network-attached devices |
| `DisplayEnhancementService` | 13.0 | Disable | display colour/enhancement processing |
| `RmSvc` | 11.1 | Disable | radio/Wi-Fi management (no Wi-Fi in the VM) |
| `DusmSvc` | 8.5 | Disable | data-usage UI |
| `TrkWks` | 7.5 | Disable | distributed link tracking for shortcuts |
| `lmhosts` | 7.4 | Disable | NetBIOS name resolution |
| `CDPSvc` | 21.1 | Disable | connected-devices platform |
| `webthreatdefsvc` | 14.9 | Disable | web threat defense (Defender is off) |
| `LanmanServer` | 12.5 | Disable | SMB server/admin shares (this VM shares nothing) |
| `Audiosrv` + `AudioEndpointBuilder` | 31.7 | Optional | RDP audio playback |
| `iphlpsvc` | 15.5 | Optional | IPv6/Teredo tunnelling |
| `ShellHWDetection` | 19.2 | Optional | AutoPlay and hardware detection |
| `TokenBroker` | 20.4 | Optional | Microsoft-account/Store sign-in |
| `DoSvc` | 27.2 | Manual | update download optimisation; starts on demand |
| `Wcmsvc` | 13.3 | Manual | connection manager/network flyout |

**How (guest, elevated)** — start with the low-risk column:

```powershell
$svcs = 'whesvc','InventorySvc','DsSvc','PcaSvc','NcdAutoSetup',
        'DisplayEnhancementService','RmSvc','DusmSvc','TrkWks','lmhosts',
        'CDPSvc','webthreatdefsvc','LanmanServer'
foreach ($s in $svcs) {
    Set-Service $s -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service $s -Force -ErrorAction SilentlyContinue
}
Set-Service DoSvc  -StartupType Manual -ErrorAction SilentlyContinue
Set-Service Wcmsvc -StartupType Manual -ErrorAction SilentlyContinue
```

**Do not touch** `UsoSvc`, `AppXSvc`, `StateRepository`, `LicenseManager`,
`CryptSvc`, `BFE`/`mpssvc`, `Winmgmt`, `EventLog`, `RpcSs`, `TermService` or
`SessionEnv`. `AppXSvc` and `StateRepository` are required to launch Start menu
and UWP apps; `LicenseManager` is activation; `BFE`/`mpssvc` is the firewall.

The clean way to ship this is a new `-AggressiveMemory` switch in
`scripts/windows/optimize-services.ps1`, not a change to the default profile.

### 7. Remove startup and consumer leftovers — 38 MiB now, prevents 100–300 MiB later

**Why.** Nothing heavy is running, but the VM still has the hooks to start
consumer components after the next logon or update:

- `CrossDeviceResume` (37.9 MiB) is the Phone Link resume feature.
- `OneDriveSetup` remains in the Network Service `Run` key
  (`HKU\S-1-5-20`) and three OneDrive scheduled tasks remain registered.
- Edge has an auto-launch `Run` value and two machine update tasks.
- Widgets (`MicrosoftWindows.Client.WebExperience`), `Microsoft.BingSearch`,
  `PeopleExperienceHost` and `XboxGameCallableUI` are still installed.
- Edge update task `MicrosoftEdgeUpdateTaskMachineCore` was in the `Running`
  state during the snapshot.

**Applied 2026-11-22.** The removable packages and startup values below were
removed, the OneDrive tasks were disabled, and the per-user Resume values were
set to `0`. Two packages are exceptions: `PeopleExperienceHost` and
`XboxGameCallableUI` are protected system apps; removal returns
`0x80073CFA`. They are not running and use no measurable RAM.

**How (guest, elevated):**

```powershell
# OneDrive leftovers
Remove-ItemProperty 'Registry::HKEY_USERS\S-1-5-20\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' `
  -Name OneDriveSetup -ErrorAction SilentlyContinue
Get-ScheduledTask | Where-Object TaskName -like 'OneDrive*' | Disable-ScheduledTask

# Edge auto-launch (keep Edge updates if you browse with Edge)
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
(Get-ItemProperty $run).PSObject.Properties |
  Where-Object Name -like 'MicrosoftEdgeAutoLaunch_*' |
  ForEach-Object { Remove-ItemProperty $run -Name $_.Name }

# Consumer packages that are removable per-user
'MicrosoftWindows.CrossDevice',
'MicrosoftWindows.Client.WebExperience',
'Microsoft.BingSearch',
'Microsoft.OneDrive.Photos' |
  ForEach-Object {
    Get-AppxPackage $_ -ErrorAction SilentlyContinue | Remove-AppxPackage
  }

# Keep them out of new profiles too
Get-AppxProvisionedPackage -Online |
  Where-Object { $_.PackageName -like 'MicrosoftWindows.CrossDevice*' -or
                 $_.PackageName -like 'MicrosoftWindows.Client.WebExperience*' -or
                 $_.PackageName -like 'Microsoft.BingSearch*' } |
  Remove-AppxProvisionedPackage -Online

# Cross-device resume: policy, per-user toggle, and backstop
$p = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Connectivity\DisableCrossDeviceResume'
New-Item -Path $p -Force | Out-Null
Set-ItemProperty -Path $p -Name 'value' -Value 1 -Type DWord
$sys = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
New-Item -Path $sys -Force | Out-Null
Set-ItemProperty -Path $sys -Name 'EnableCdp' -Value 0 -Type DWord
$cfg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration'
Set-ItemProperty -Path $cfg -Name 'IsResumeAllowed' -Value 0 -Type DWord
Set-ItemProperty -Path $cfg -Name 'IsOneDriveResumeAllowed' -Value 0 -Type DWord

# sihost relaunches CrossDeviceResume even after the package is gone.
# Keep it dead after each logon; taskkill returns 128 when it is already gone.
schtasks.exe /create /f /sc ONLOGON /delay 0000:03 `
  /tn '\WindowsSlim\Kill CrossDeviceResume' `
  /tr 'taskkill.exe /im CrossDeviceResume.exe /f' /ru SYSTEM /rl HIGHEST
```

**Trade-off.** Phone Link resume, widgets, Bing web results and OneDrive Photos
disappear. The logon kill task is a deliberate backstop; it costs one command
per logon and no resident memory. People/Xbox stay installed but idle.

### 8. Fix the vCPU topology — host overhead, no guest RAM change

**Why.** The domain has `<vcpu>6</vcpu>` and no topology. QEMU defaults to six
single-core sockets; Windows 11 Pro accepts at most two physical sockets, so
`Win32_Processor` shows 2 CPUs and four vCPUs are wasted. QEMU still creates
and schedules six vCPU threads.

**Applied 2026-11-22.** The domain is now at **2 vCPUs**. The guest reports
2 logical CPUs across 2 sockets, which is within the Windows 11 Pro limit; no
vCPU is hidden. No `<topology>` element is needed for this option.

**How.** For this workload, 2 vCPUs are enough:

```bash
virsh -c qemu:///system setvcpus win11-stock 2 --config
virsh -c qemu:///system setvcpus win11-stock 2 --config --maximum
# or: virsh edit win11-stock, then <vcpu placement='static'>2</vcpu>
```

If 6 usable CPUs are wanted instead, keep `<vcpu>6</vcpu>` and add a topology
under `<cpu>`:

```xml
<cpu mode='host-passthrough' check='none'>
  <topology sockets='1' cores='6' threads='1'/>
</cpu>
```

A shutdown/start is required. Expected host saving is only tens of MiB, but it
removes four useless threads and makes monitoring honest.

### 9. Appliance shell or SSH-only mode — another 0.6–1.2 GiB, at a cost

**Why.** The Windows shell stack is the largest guest consumer while connected:

| Component | MiB |
| --- | ---: |
| `explorer` | 283.1 |
| `StartMenuExperienceHost` | 134.3 |
| `ShellExperienceHost` | 69.7 |
| `sihost` | 47.8 |
| `ShellHost` | 41.6 |
| `CrossDeviceResume` | 37.9 |
| `ctfmon` (session 1) | 32.8 |
| `RuntimeBroker` | 23.3 |
| **Total** | **~671** |

If the VM exists only to run one application over RDP, set a minimal shell for
the account (`HKCU\Software\Microsoft\Windows NT\CurrentVersion\Winlogon\Shell`)
to that application or to `cmd.exe`. Explorer, Start menu and the shell hosts
never start. This saves ~0.65 GiB while connected. It is a **high-risk,
high-maintenance** option: no taskbar/Start, file pickers may behave
differently, and recovery needs an SSH session. Keep the default shell unless
the VM is a single-purpose appliance.

**SSH-only** is the extreme version: disable RDP (`TermService`), do not keep a
graphical session, and use SSH for command-line work. That frees session 1
(~1.08 GiB), `TermService` (~100 MiB), `rdpclip` and RDP session services —
over 1.2 GiB — but removes the GUI. It contradicts the documented role
(browser/Office over RDP), so it is listed only for completeness.

### 10. Things that look tempting but are not worth it

| Item | MiB | Why not |
| --- | ---: | --- |
| `Registry` | 119.7 | Kernel registry cache. Killing it is impossible and touching it is pointless. |
| Console lock screen (`LogonUI` + `dwm` + `winlogon` + `csrss` + `fontdrvhost`) | 191.4 | Created by Windows even without a console user. No supported way to remove it. |
| `WUDFHost` | 39.8 | One user-mode driver host. Identify the device before disabling; it may be needed by a VirtIO/CD device. |
| `dwm` in session 1 | 109.5 | Required for RDP desktop composition. |
| `MemoryCompression` | off | At 1.62 GiB commit / 4 GiB RAM there is no pressure. Enabling it costs CPU and a compression store. Revisit only if the guest is squeezed. |
| Pagefile | 1.9 GiB | It consumes disk, not RAM; peak usage is 0. Leave it. |
| Windows Update (`BITS`/`TiWorker`) | ~50 | Transient and security-relevant. Defer scans instead of disabling servicing. |

### 11. Search UI removal (applied 2026-11-22)

**Why.** Disabling `WSearch` stops indexing but not `SearchHost.exe`, which the
shell starts on demand and which cost ~120 MiB in the RDP session. Disabling
`SearchEngine-Client-Package` alone did not stop it, and IFEO was ignored by
packaged-app activation. Renaming the binary works until Windows restores the
WinSxS hardlink, so a process-start guard is the reliable part.

**How.** Disable the feature, stop the process, rename the binaries, and add a
permanent WMI kill guard:

```powershell
# 1. Feature (reboot needed to complete)
Disable-WindowsOptionalFeature -Online -FeatureName SearchEngine-Client-Package -NoRestart

# 2. Stop and rename the UI binaries (they are hardlinks into WinSxS)
$files = @(
  'C:\WINDOWS\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\SearchHost.exe',
  'C:\WINDOWS\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\SearchProviderHost.exe',
  'C:\Windows\SystemApps\Shared\AOT\SearchProviderHost.exe'
)
Get-Process SearchHost -ErrorAction SilentlyContinue | Stop-Process -Force
foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    takeown.exe /f $f /a | Out-Null
    icacls.exe $f /grant '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
    Rename-Item -LiteralPath $f -NewName ([IO.Path]::GetFileName($f) + '.disabled') -Force
}

# 3. Permanent WMI guard: kill any search process the moment it starts
$ns = 'root\subscription'
$filterName = 'WindowsSlim-SearchHost-Start'
$consumerName = 'WindowsSlim-SearchHost-Kill'
$query = "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'SearchHost.exe' OR ProcessName = 'SearchProviderHost.exe' OR ProcessName = 'SearchIndexer.exe' OR ProcessName = 'SearchProtocolHost.exe' OR ProcessName = 'SearchFilterHost.exe' OR ProcessName = 'SearchApp.exe'"
$filter = Set-WmiInstance -Namespace $ns -Class __EventFilter -Arguments @{
    Name = $filterName; EventNameSpace = 'root\cimv2'
    QueryLanguage = 'WQL'; Query = $query
}
$consumer = Set-WmiInstance -Namespace $ns -Class CommandLineEventConsumer -Arguments @{
    Name = $consumerName
    ExecutablePath = 'C:\Windows\System32\taskkill.exe'
    CommandLineTemplate = 'C:\Windows\System32\taskkill.exe /PID %ProcessID% /F'
}
Set-WmiInstance -Namespace $ns -Class __FilterToConsumerBinding -Arguments @{
    Filter = $filter; Consumer = $consumer
} | Out-Null
```

`Win32_ProcessStartTrace` fires for every process; the filter limits it to the
search executables. The consumer runs as SYSTEM. It was tested with a dummy
`SearchHost.exe` and killed it. `SearchHost.exe.bak` and the `.disabled` files
remain as hardlinks, so the change is reversible.

**Rollback.** Remove the WMI binding/filter/consumer, rename the `.disabled`
files back, then re-enable the feature and `WSearch`:

```powershell
$ns = 'root\subscription'
Get-WmiObject -Namespace $ns -Class __FilterToConsumerBinding |
  Where-Object { $_.Filter -like '*WindowsSlim-SearchHost-Start*' } | ForEach-Object { $_.Delete() }
Get-WmiObject -Namespace $ns -Class __EventFilter -Filter "Name='WindowsSlim-SearchHost-Start'" | ForEach-Object { $_.Delete() }
Get-WmiObject -Namespace $ns -Class CommandLineEventConsumer -Filter "Name='WindowsSlim-SearchHost-Kill'" | ForEach-Object { $_.Delete() }
Get-ChildItem 'C:\Windows\SystemApps' -Recurse -Filter '*.exe.disabled' |
  ForEach-Object { Rename-Item -LiteralPath $_.FullName -NewName ($_.Name -replace '\.disabled$','') }
Enable-WindowsOptionalFeature -Online -FeatureName SearchEngine-Client-Package
Set-Service WSearch -StartupType Automatic
```

### 12. Replace the Start menu with PowerToys Run (applied 2026-11-22)

**Why.** `StartMenuExperienceHost.exe` (the Win-key tiles window) cost
**145.8 MiB**. Everything was installed first but is a **file search window**,
not a Raycast-style command launcher. PowerToys Run is local, Microsoft-signed,
stable and extensible. Raycast for Windows exists but is account/cloud-centric
and heavier; CmdPal (PowerToys' newer successor) measured 176 MiB plus the 46 MiB
host and is less mature. PowerToys Run **idles as low as ~17 MiB** (8 MiB host
+ 8 MiB launcher), typically 80–105 MiB after use, rises to ~190 MiB after the
UI warms, and peaks around ~235 MiB. That is **far lighter than the 145.8 MiB
Start menu at idle**, but ~43 MiB heavier while the UI is warm — the cost of the
functionality.

**Install.** The per-user package installs with winget:

```powershell
winget.exe install --id Microsoft.PowerToys -e --silent `
  --accept-package-agreements --accept-source-agreements --disable-interactivity
```

That installed PowerToys 0.102.3101 at
`C:\Users\Windows-PC\AppData\Local\PowerToys\PowerToys.exe`.

**Trim to Run only.** With every module enabled, PowerToys used about **740 MiB**
(`ColorPickerUI`, `Settings`, `ShortcutGuide`, `Peek` and others all resident).
Stop every PowerToys/CmdPal process, edit
`%LOCALAPPDATA%\Microsoft\PowerToys\settings.json`, remove the stale
`settings.json.cli-lock`, and restart:

```powershell
$main = "$env:LOCALAPPDATA\Microsoft\PowerToys\settings.json"
Get-Process PowerToys*,Microsoft.CmdPal* | Stop-Process -Force
Start-Sleep -Seconds 3
$j = Get-Content $main -Raw | ConvertFrom-Json
foreach ($p in $j.enabled.PSObject.Properties) { $p.Value = $false }
$j.enabled.'PowerToys Run' = $true
$j.startup = $true
$j.show_tray_icon = $true
$j.enable_quick_access = $false
$j.download_updates_automatically = $false
[IO.File]::WriteAllText($main, ($j | ConvertTo-Json -Depth 10),
  (New-Object Text.UTF8Encoding($false)))   # no BOM
Remove-Item "$env:LOCALAPPDATA\Microsoft\PowerToys\settings.json.cli-lock" -Force -ErrorAction SilentlyContinue
```

The **BOM matters**: the first write used `Set-Content -Encoding UTF8` (with a
BOM), which PowerToys ignored; it fell back to “all modules on.” Writing UTF-8
without BOM produced the intended single-module state.

**Hotkey and auto-start.** PowerToys Run uses **Alt+Space** by default. Its
`launcher-log` records “PT Run is going to use default shortcut”; the Run settings
file has `open_powerlauncher` set to Alt+Space. Simulated `SendKeys` does not
trigger PowerToys’ low-level keyboard hook, so the final check is a physical
Alt+Space keypress. The per-user build later exposed its own
`\PowerToys\Autorun for Windows-PC` task (3 s delay, `PowerToys.exe`); that task
is now the only launcher autostart, and the duplicate
`\WindowsSlim\StartPowerToys` was removed. The original registration was:

```powershell
$trigger = New-ScheduledTaskTrigger -AtLogOn -User 'Windows-VM\Windows-PC'
$trigger.Delay = 'PT10S'
$action = New-ScheduledTaskAction -Execute 'C:\Users\Windows-PC\AppData\Local\PowerToys\PowerToys.exe'
$principal = New-ScheduledTaskPrincipal -UserId 'Windows-VM\Windows-PC' -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskPath '\WindowsSlim\' -TaskName 'StartPowerToys' `
  -Trigger $trigger -Action $action -Principal $principal -Force
```

**Remove Everything.** Everything’s service, HKLM Run value, shortcuts and folder
were removed so only one launcher remains:

```powershell
Get-Process Everything | Stop-Process -Force
Stop-Service Everything -Force
& 'C:\Program Files\Everything\Everything.exe' -uninstall
Remove-Item 'C:\Program Files\Everything' -Recurse -Force
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name Everything
Remove-Item "$env:USERPROFILE\Desktop\Everything.lnk" -Force
```

**Block Start.** Stop the Start host, take ownership of its hardlink, and rename
it; add the permanent WMI guard with the query below (same pattern as section
11):

```powershell
$exe = 'C:\Windows\SystemApps\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\StartMenuExperienceHost.exe'
Get-Process StartMenuExperienceHost -ErrorAction SilentlyContinue | Stop-Process -Force
takeown.exe /f $exe /a
icacls.exe $exe /grant '*S-1-5-32-544:F' '*S-1-5-18:F'
Rename-Item -LiteralPath $exe -NewName 'StartMenuExperienceHost.exe.disabled' -Force
```

```text
Filter:  WindowsSlim-StartMenu-Start
Query:   SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'StartMenuExperienceHost.exe'
Consumer: WindowsSlim-StartMenu-Kill -> taskkill /PID %ProcessID% /F
```

**Verification.** The Start host is absent; Ctrl+Esc produces no process and
Explorer/`sihost`/`ShellExperienceHost` stay up. PowerToys host + Run are the only
PowerToys processes; no Everything service or process remains. Press Alt+Space to
verify the launcher physically.

**Memory.** PowerToys **idles as low as ~17 MiB** (8 MiB host + 8 MiB launcher),
typically 80–105 MiB after use, rises to ~190 MiB after the UI warms, and peaks
around ~235 MiB. At idle it is far lighter than the 145.8 MiB Start menu; while
warm it costs ~43 MiB more. Everything was lighter (~30–62 MiB) but was only a
file search window. The all-modules PowerToys default was ~740 MiB; trimming to
Run is the key.

**Rollback.** Remove the PowerToys autorun task (or let the uninstall remove it),
uninstall PowerToys, remove the Start guard, and rename the Start host back:

```powershell
Unregister-ScheduledTask -TaskPath '\PowerToys\' -TaskName 'Autorun for Windows-PC' -Confirm:$false
winget.exe uninstall --id Microsoft.PowerToys -e --silent
$ns = 'root\subscription'
Get-WmiObject -Namespace $ns -Class __FilterToConsumerBinding |
  Where-Object { $_.Filter -like '*WindowsSlim-StartMenu-Start*' } | ForEach-Object { $_.Delete() }
Get-WmiObject -Namespace $ns -Class __EventFilter -Filter "Name='WindowsSlim-StartMenu-Start'" | ForEach-Object { $_.Delete() }
Get-WmiObject -Namespace $ns -Class CommandLineEventConsumer -Filter "Name='WindowsSlim-StartMenu-Kill'" | ForEach-Object { $_.Delete() }
Rename-Item -LiteralPath 'C:\Windows\SystemApps\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\StartMenuExperienceHost.exe.disabled' `
  -NewName 'StartMenuExperienceHost.exe'
```


## Expected result

These figures use the applied 4 GiB cap, the guest trims and PowerToys Run.
Measured with `vm-stats.sh`, `dommemstat` and the guest counters on 2026-11-22.

| Scenario | Guest working set | Guest used | Host QEMU RSS |
| --- | ---: | ---: | ---: |
| Current, console session active | 1.51 GiB | ~1.23 GiB | **~2.0 GiB with KSM** (4.10 without) |
| RDP disconnected, before the 5-min timeout | ~1.5 GiB | ~1.2 GiB | ~2.0 GiB |
| After timeout/logoff (estimate) | ~1.0 GiB | ~1.0 GiB | ~2.0 GiB |
| With KSM zero-page merging | unchanged | unchanged | ~2.0 GiB |
| Heavy FL Studio/browser load | up to ~3.5 GiB | up to ~3 GiB | 4.10 GiB (hard cap) |

Replacing Start with PowerToys Run removes **145.8 MiB** and adds **~17 MiB at
idle** (net **~129 MiB saved**), **~80–105 MiB after use** (net **~40–65 MiB
saved**), and ~200 MiB while warm (a net cost). The 4 GiB cap removed **~4.0 GiB**
of host RSS, and KSM zero-page merging removed another **~2.1 GiB** at idle;
guest tuning now only makes the remaining cap more comfortable.

## Proposed repository changes

The running domain has drifted from the repository. `installation-mode.nix`
still says `memory = 12288; vcpus = 6;`, while the live domain is **4 GiB with 2
vCPUs**. The installer also hard-codes `--memballoon none` and does not pass a
requested topology. A future reinstall would therefore recreate a 12 GiB /
6-vCPU / balloon-less guest.

1. **`installation-mode.nix`** — set `memory = 4096; vcpus = 2;` (or add
   `memoryMax = 8192` for the elastic variant) and update the comment that
   currently recommends 8–12 GiB.
2. **`install/windows-vm-create.sh`** — replace the unconditional
   `--memballoon none` with an option. For the simple profile keep `none` and
   pass `--memory 4096`; for the elastic profile pass
   `--memory memory=4096,maxmemory=8192 --memballoon virtio` and install the
   balloon driver during provisioning.
3. **`install/windows-vm-create.sh`** — add the CPU topology (or default
   `--vcpus 2`) so Windows does not silently discard four vCPUs.
4. **`scripts/vm-memory.sh`** — add a `--current/--max` mode. Today it sets
   maximum and current to the same value, which is correct only for a
   balloon-less guest. Refuse `current < max` when the domain has
   `memballoon model='none'`.
5. **`scripts/windows/trim-memory.ps1`** — add `-Aggressive` for the per-user
   services, `CrossDevice`, Edge auto-launch, the Network Service `OneDriveSetup`
   value and OneDrive tasks. Keep the current default behaviour.
6. **`scripts/windows/optimize-services.ps1`** — add `-AggressiveMemory` with
   the table from section 6. Do not fold it into the default `minimal` profile.
7. **`scripts/windows/verify-minimal.ps1`** — check `Taskmgr`, the four
   per-user service start values, `whesvc`, the RDP timeouts, the
   `\WindowsSlim\Kill CrossDeviceResume` task, and (for the elastic profile)
   the balloon driver.
8. **`docs/windows-vm.md`** — update the *Memory* section with the measured
   numbers and point here. The current text correctly says the host pays the
   full allocation; it should now recommend 4 GiB and explain the balloon
   caveat.
9. **`README.md`** — add this document to the repository-layout table.
10. **`scripts/windows/toggle-search.ps1`** — add an `-Aggressive` switch that
    disables `SearchEngine-Client-Package`, renames the search binaries, and
    installs the tested `WindowsSlim-SearchHost-Start` WMI kill guard. Document
    that `WSearch` alone leaves `SearchHost.exe` free to start on demand and
    that feature removal plus renaming alone can be repaired by CBS.
11. **`scripts/windows/powertoys-run.ps1`** — install PowerToys from winget,
    write the Run-only `settings.json` without BOM, enable one logon task
    (`\PowerToys\Autorun` or `\WindowsSlim\StartPowerToys`), and optionally
    rename/guard `StartMenuExperienceHost.exe`. Add `-Restore` to remove the
    task, uninstall PowerToys, and restore Start.

## Verification checklist

Host:

```bash
virsh -c qemu:///system dominfo win11-stock | grep -E 'CPU\(s\)|Max memory|Used memory'
virsh -c qemu:///system dommemstat win11-stock
./scripts/vm-stats.sh win11-stock
cat /sys/kernel/mm/ksm/run
cat /sys/kernel/mm/ksm/use_zero_pages
grep -E 'pages_sharing|pages_shared' /sys/kernel/mm/ksm/*
```

Guest:

```bash
./scripts/win-ssh.sh 'Get-Process | Sort-Object WS -Descending | Select-Object -First 15 Name,@{n="MB";e={[int]($_.WS/1MB)}}'
./scripts/win-ssh.sh '(Get-CimInstance Win32_OperatingSystem) | Select TotalVisibleMemorySize,FreePhysicalMemory'
./scripts/win-ssh.sh 'Get-Service whesvc,WpnUserService_*,CDPUserSvc_*,cbdhsvc_* | Select Name,Status,StartType'
```

## Rollback

| Change | Rollback |
| --- | --- |
| 4 GiB allocation | `sudo ./scripts/vm-memory.sh 8 win11-stock` |
| Balloon device | remove `<memballoon>` and the `currentMemory` line, shut down/start |
| KSM | `echo 0 > /sys/kernel/mm/ksm/run`; if persisted, remove the `ksm-zero-pages` unit and rebuild |
| RDP timeouts | set both values back to `0` |
| Per-user / machine services | `Set-Service <name> -StartupType Automatic` (or `Manual` for `WinHttpAutoProxySvc`); `DoSvc` is `LaunchProtected`, so reverse it offline with `Start=2` in the `SYSTEM` hive |
| Startup/package cleanup | re-enable the scheduled task, or reinstall the AppX package from the Store |
| Search feature | `Enable-WindowsOptionalFeature -Online -FeatureName SearchEngine-Client-Package` + reboot; set `WSearch` back to Automatic if indexing is wanted |
| Search WMI guard | remove the binding/filter/consumer and rename the `.disabled` files back (commands in section 11) |
| Shell replacement | remove the `Shell` value under `Winlogon`, then sign out/in |
| CPU topology | `virsh edit` back to 6 vCPUs without topology |

## See also

- [`windows-vm.md`](windows-vm.md) — guest install record, RDP/SSH, helper CD
- [`windows-scheduled-tasks.md`](windows-scheduled-tasks.md) — task inventory
  and safe-to-disable analysis
- [`../scripts/vm-memory.sh`](../scripts/vm-memory.sh) — allocation helper
- [`../scripts/vm-stats.sh`](../scripts/vm-stats.sh) — host + guest summary
- [`../install/windows-vm-create.sh`](../install/windows-vm-create.sh) — VM
  creation defaults