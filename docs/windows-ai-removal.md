# Windows AI removal: services, apps, tasks and policies

Guest: `win11-stock` — Windows 11 build 26300 (26H1) — applied
**2026-11-22**.  This document records what Microsoft AI components existed,
what was removed or disabled, and how to verify or roll it back.  Read-only
inventory commands are in
[`windows-vm-inventory-commands.md`](windows-vm-inventory-commands.md#ai-components).

## What was present

| Component | State before |
| --- | --- |
| `WSAIFabricSvc` (“Host für Windows KI-Komponenten”) | Stopped, **Disabled** (already from the earlier trim) |
| `MicrosoftWindows.Client.CoreAI` | Installed, **NonRemovable=True**, `SignatureKind=System` |
| `Microsoft.AIFabric.CBS.1.6` | Installed, **IsFramework=True**, **NonRemovable=True**, System; removed with EndOfLife + backup |
| Microsoft Copilot app | **Not installed** |
| Copilot/Recall/Click-to-Do/AIFabric processes | **None** |
| `Recall` optional feature | **DisabledWithPayloadRemoved** |
| AI scheduled tasks | 6 under `\Microsoft\Windows\WindowsAI\` (ClickToDo, Recall, Settings) |
| AI policies | `DisableAIDataAnalysis=1`, `AllowRecallEnablement=0`, `DisableClickToDo=1`, `TurnOffWindowsCopilot=1`, `ShowCopilotButton=0` already set |

`BITS` matched a naive “AI” search but is the Background Intelligent Transfer
Service; it was left alone.

## Removal

### 1. AI scheduled tasks

All six tasks were disabled where possible and unregistered:

```powershell
Get-ScheduledTask |
  Where-Object {
    $_.TaskPath -like '\Microsoft\Windows\WindowsAI\*' -or
    $_.TaskName -match 'Copilot|Recall|AIFabric|WindowsAI|ClickToDo|Semantic|Intelligen'
  } |
  ForEach-Object {
    $path = $_.TaskPath; $name = $_.TaskName
    try { Disable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop } catch {}
    try { Unregister-ScheduledTask -TaskPath $path -TaskName $name -Confirm:$false -ErrorAction Stop } catch {}
  }
```

Some `Disable-ScheduledTask` calls returned access denied, but
`Unregister-ScheduledTask` removed every task.  The final
`Get-ScheduledTask -TaskPath '\Microsoft\Windows\WindowsAI\*'` is empty.

### 2. Copilot, Recall, Click-to-Do, Paint, Notepad and Edge policies

```powershell
$machine = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'
$user    = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot'
foreach ($key in $machine,$user) {
  if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
  Set-ItemProperty $key -Name TurnOffWindowsCopilot   -Value 1 -Type DWord
  Set-ItemProperty $key -Name RemoveMicrosoftCopilotApp -Value 1 -Type DWord
}

$ai = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
if (-not (Test-Path $ai)) { New-Item -Path $ai -Force | Out-Null }
Set-ItemProperty $ai -Name DisableAIDataAnalysis  -Value 1 -Type DWord
Set-ItemProperty $ai -Name AllowRecallEnablement  -Value 0 -Type DWord
Set-ItemProperty $ai -Name DisableClickToDo       -Value 1 -Type DWord

$paint = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'
if (-not (Test-Path $paint)) { New-Item -Path $paint -Force | Out-Null }
Set-ItemProperty $paint -Name DisableCocreator      -Value 1 -Type DWord
Set-ItemProperty $paint -Name DisableGenerativeFill -Value 1 -Type DWord
Set-ItemProperty $paint -Name DisableImageCreator   -Value 1 -Type DWord

$notepad = 'HKLM:\SOFTWARE\Policies\WindowsNotepad'
if (-not (Test-Path $notepad)) { New-Item -Path $notepad -Force | Out-Null }
Set-ItemProperty $notepad -Name DisableAIFeatures -Value 1 -Type DWord

$edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
if (-not (Test-Path $edge)) { New-Item -Path $edge -Force | Out-Null }
foreach ($name in 'CopilotEnabled','EdgeCopilotFeaturesEnabled','HubsSidebarEnabled',
                  'CopilotPageContext','CopilotCDPPageContext','DiscoverPageContextEnabled') {
  Set-ItemProperty $edge -Name $name -Value 0 -Type DWord
}

$ex = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-ItemProperty $ex -Name ShowCopilotButton -Value 0 -Type DWord
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
  -Name ShowCopilotButton -Value 0 -Type DWord

$expl = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
if (-not (Test-Path $expl)) { New-Item -Path $expl -Force | Out-Null }
Set-ItemProperty $expl -Name SettingsPageVisibility -Value 'hide:aicomponents' -Type String
```

`DisableAIDataAnalysis`, `AllowRecallEnablement`, `DisableClickToDo`,
`TurnOffWindowsCopilot` and `ShowCopilotButton` were already set by the earlier
AI/trim scripts; the block above makes the state explicit and adds the
Paint/Notepad/Edge/settings-page controls.

### 3. AI service

```powershell
Set-Service WSAIFabricSvc -StartupType Disabled
Stop-Service WSAIFabricSvc -Force
```

### 4. CoreAI package

`MicrosoftWindows.Client.CoreAI` is marked `NonRemovable`, so plain
`Remove-AppxPackage` returns `0x80073CFA`.  Marking its per-user EndOfLife key
first allowed removal:

```powershell
$pkg = Get-AppxPackage MicrosoftWindows.Client.CoreAI
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$eol = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\EndOfLife\$sid\$($pkg.PackageFullName)"
New-Item -Path $eol -Force | Out-Null
Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers
```

`Remove-AppxPackage -AllUsers` returned **REMOVED** for CoreAI.  Verify it is
gone with `Get-AppxPackage MicrosoftWindows.Client.CoreAI` (empty).

### 5. AIFabric framework (removed with backup)

`Microsoft.AIFabric.CBS.1.6` is a **framework** with `NonRemovable=True`, but
the same per-user EndOfLife method that removed CoreAI also worked for it.  A
local backup was taken first (8.6 MB package plus the AppX registry key):

```powershell
$pkg = Get-AppxPackage Microsoft.AIFabric.CBS.1.6
$backup = 'C:\ProgramData\WindowsSlim\backup\AIFabric-CBS-1.6'
New-Item -Path $backup -ItemType Directory -Force | Out-Null
robocopy $pkg.InstallLocation $backup /E /COPYALL /R:1 /W:1
reg.exe export "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications\$($pkg.PackageFullName)" `
  'C:\ProgramData\WindowsSlim\backup\AIFabric-InboxApplications.reg' /y

$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$eol = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\EndOfLife\$sid\$($pkg.PackageFullName)"
New-Item -Path $eol -Force | Out-Null
Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers
```

`Remove-AppxPackage -AllUsers` returned **REMOVED**; `Get-AppxPackage` now
reports **no AI packages**.  The backup is at
`C:\ProgramData\WindowsSlim\backup\AIFabric-CBS-1.6` with
`AIFabric-InboxApplications.reg` beside it.  No offline disk edit was needed.

## Verification

```powershell
Get-ScheduledTask | Where-Object { $_.TaskPath -like '\Microsoft\Windows\WindowsAI\*' }
Get-Process | Where-Object {
  $_.ProcessName -match 'Copilot|Recall|AIFabric|Intelligen|Semantic|ClickToDo|CoreAI|WindowsAI'
}
Get-Service WSAIFabricSvc | Select-Object Name,Status,StartType
Get-AppxPackage | Where-Object {
  $_.Name -match 'AIFabric|Copilot|Recall|Intelligen|Semantic|ClickToDo|CoreAI|WindowsAI|Windows\.AI'
}
Get-WindowsOptionalFeature -Online -FeatureName Recall |
  Select-Object FeatureName,State
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\WindowsNotepad' |
  Select-Object DisableAIFeatures
```

Observed immediately after the change:

- AI task list: **empty**.
- AI processes: **none**.
- `WSAIFabricSvc`: **Stopped / Disabled**.
- AI packages: **none remained** immediately after online removal.
- `Recall`: **DisabledWithPayloadRemoved**.
- Notepad `DisableAIFeatures=1`; Paint policies all `1`; Edge Copilot policies
  all `0`; `SettingsPageVisibility=hide:aicomponents`.
- Microsoft Copilot app: not installed, so no app to remove.

## Persistence after reboot (online method failed)

Online removal is **not durable across a Windows servicing boot**.  After the
first restart, CBS removed the EndOfLife keys and re-registered
`MicrosoftWindows.Client.CoreAI` and `Microsoft.AIFabric.CBS.1.6`.  The AI
tasks did not return, `WSAIFabricSvc` stayed Disabled, and all policies
persisted — so no AI process or service runs, but the package files were present
again.

An **AtLogOn** re-cleanup task was tried as a stopgap.  It worked only in an
interactive session and logged `0x80073CFA` (“part of Windows, cannot be
removed”) when the packages were already present at boot, so it was **removed**
after the offline edit succeeded.  The offline method below is the durable fix.

## Offline removal (applied 2026-11-22)

The guest was shut down and the raw disk edited directly.  This is the durable
method on build 26300.

### Backup

`/root/ai-offline-backup-2026-11-22` on the NixOS host (158 MB) contains:

- `SOFTWARE.bak` (90 MB) and `SYSTEM.bak` (16 MB) — full registry hives,
- `SystemApps/` — both package folders,
- `WinSxS/` — all five component folders,
- `Tasks/WindowsAI/` — the (already empty) task folder.

The pre-existing online backup at
`C:\ProgramData\WindowsSlim\backup\AIFabric-CBS-1.6` is still inside the guest.

### Procedure

```bash
# host, as root — guest shut off
modprobe nbd max_part=16
qemu-nbd -f raw -c /dev/nbd0 /var/lib/libvirt/images/win11-stock.raw
ntfs-3g /dev/nbd0p3 /mnt/win
```

Remove the package payloads and their component-store folders:

```bash
rm -rf /mnt/win/Windows/SystemApps/Microsoft.AIFabric.CBS.1.6_8wekyb3d8bbwe
rm -rf /mnt/win/Windows/SystemApps/MicrosoftWindows.Client.CoreAI_cw5n1h2txyewy
rm -rf /mnt/win/Windows/WinSxS/amd64_microsoft-aifabric-cbs-1-6_*
rm -rf /mnt/win/Windows/WinSxS/amd64_userexperience-coreai_*
rm -rf /mnt/win/Windows/System32/Tasks/Microsoft/Windows/WindowsAI
```

Delete both `InboxApplications` keys with `hivexsh` (plain `del` does not take
an argument; `cd` into the key first, then `del`):

```bash
hivexsh -w /mnt/win/Windows/System32/config/SOFTWARE <<'EOF'
cd \Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications\Microsoft.AIFabric.CBS.1.6_1.6.955.100_x64__8wekyb3d8bbwe
del
cd \Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications\MicrosoftWindows.Client.CoreAI_1000.26100.10068.0_x64__cw5n1h2txyewy
del
commit
quit
EOF
sync
umount /mnt/win
qemu-nbd -d /dev/nbd0
```

There is **no `hiberfil.sys`**, so no Fast Startup image can restore the old
state.

### Verification after boot

- `Get-AppxPackage` filtered for `AIFabric|CoreAI|Copilot|WindowsAI`: **empty**.
- `\Microsoft\Windows\WindowsAI\*` tasks: **none**.
- `Get-Process` filtered for AI names: **none**; `WSAIFabricSvc` Stopped/Disabled.
- `Test-Path C:\Windows\SystemApps\MicrosoftWindows.Client.CoreAI_cw5n1h2txyewy`
  and the AIFabric folder: **False**.
- `DISM /Online /Cleanup-Image /CheckHealth`: **no component-store
  corruption**.
- Shell, SSH, Start-menu/Search blocks and all other trims unaffected.
- 77 processes, 6.76 GB free, 1.74 GB working set shortly after logon.

### Caveats

- This bypasses CBS.  The `COMPONENTS` hive can still reference the deleted
  components, so a future cumulative update or in-place upgrade may try to
  service them, report a missing payload, or re-add the packages.  Re-check
  after servicing and repeat the offline edit if needed.
- Windows Update cannot repair the deleted components from the local store;
  keep the host backup above until the next feature update is validated.
- The `StateRepository-*.srd` database is left to Windows to reconcile; do not
  hand-edit it.

## Behaviour and caveats

- Edge, Paint and Notepad read their policies at process start.  **Restart
  Edge/Paint/Notepad** (or sign out) for the controls to take effect; Edge was
  running during the change.
- CoreAI and AIFabric were removed **offline** after the online method failed to
  survive a reboot; both package folders, all five WinSxS components, the
  `WindowsAI` task folder and both `InboxApplications` keys are gone.  No logon
  cleanup task remains.
- A rollback copy of AIFabric is at
  `C:\ProgramData\WindowsSlim\backup\AIFabric-CBS-1.6` with
  `AIFabric-InboxApplications.reg`; full package, WinSxS and hive backups are on
  the host under `/root/ai-offline-backup-2026-11-22`.
- Windows updates can add new AI tasks/components; re-run the AI inventory after
  servicing.
- This change is about privacy and removing AI surfaces, not RAM: the AI
  components were already idle, so the working-set change is negligible.
- Recall’s optional feature was already `DisabledWithPayloadRemoved`; no
  additional feature removal was needed.

## Rollback

```powershell
# Service and optional feature
Set-Service WSAIFabricSvc -StartupType Automatic
Start-Service WSAIFabricSvc
Enable-WindowsOptionalFeature -Online -FeatureName Recall

# Remove AI policy values selectively, for example:
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name TurnOffWindowsCopilot,RemoveMicrosoftCopilotApp
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -Name DisableAIDataAnalysis,AllowRecallEnablement,DisableClickToDo
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint' -Name DisableCocreator,DisableGenerativeFill,DisableImageCreator
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\WindowsNotepad' -Name DisableAIFeatures
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name CopilotEnabled,EdgeCopilotFeaturesEnabled,HubsSidebarEnabled,CopilotPageContext,CopilotCDPPageContext,DiscoverPageContextEnabled
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name SettingsPageVisibility
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name ShowCopilotButton -Value 1 -Type DWord
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name ShowCopilotButton -Value 1 -Type DWord

# Allow CoreAI/AIFabric to be reinstalled: remove both EndOfLife keys.
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\EndOfLife' -Recurse |
  Where-Object { $_.PSChildName -like 'MicrosoftWindows.Client.CoreAI*' -or
                 $_.PSChildName -like 'Microsoft.AIFabric.CBS.1.6*' } |
  Remove-Item -Recurse -Force

# Restore AIFabric from the local backup, then import its AppX registration.
$backup = 'C:\ProgramData\WindowsSlim\backup\AIFabric-CBS-1.6'
reg.exe import 'C:\ProgramData\WindowsSlim\backup\AIFabric-InboxApplications.reg'
Add-AppxPackage -Register "$backup\AppxManifest.xml" -DisableDevelopmentMode
```

### Restoring the offline-removed packages

The offline edit deleted the payloads and their AppX registration, so the
online rollback above alone is not enough.  With the guest shut off, copy the
payloads and the pre-edit `SOFTWARE` hive back from the host backup:

```bash
# host, as root — guest shut off
qemu-nbd -f raw -c /dev/nbd0 /var/lib/libvirt/images/win11-stock.raw
ntfs-3g /dev/nbd0p3 /mnt/win
cp -a /root/ai-offline-backup-2026-11-22/SystemApps/* /mnt/win/Windows/SystemApps/
cp -a /root/ai-offline-backup-2026-11-22/WinSxS/*      /mnt/win/Windows/WinSxS/
cp -a /root/ai-offline-backup-2026-11-22/Tasks/WindowsAI \
      /mnt/win/Windows/System32/Tasks/Microsoft/Windows/
cp -a /root/ai-offline-backup-2026-11-22/SOFTWARE.bak \
      /mnt/win/Windows/System32/config/SOFTWARE
sync; umount /mnt/win; qemu-nbd -d /dev/nbd0
```

Restoring `SOFTWARE.bak` re-adds both `InboxApplications` keys but also reverts
any `SOFTWARE` changes made after the backup was taken (it was captured moments
before the edit).  On the next boot, register the packages:

```powershell
Add-AppxPackage -Register 'C:\Windows\SystemApps\MicrosoftWindows.Client.CoreAI_cw5n1h2txyewy\AppxManifest.xml' -DisableDevelopmentMode
Add-AppxPackage -Register 'C:\Windows\SystemApps\Microsoft.AIFabric.CBS.1.6_8wekyb3d8bbwe\AppxManifest.xml' -DisableDevelopmentMode
```

CoreAI has no in-guest backup; the host backup above is its only copy.  AI
scheduled tasks are normally recreated by Windows servicing; they can be
re-registered by the relevant Windows component if its feature is re-enabled.