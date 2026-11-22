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
| `Microsoft.AIFabric.CBS.1.6` | Installed, **IsFramework=True**, **NonRemovable=True**, System |
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

### 5. AIFabric framework (protected)

`Microsoft.AIFabric.CBS.1.6` is a **framework** and `NonRemovable=True`, so it
cannot be uninstalled per-user; removal returns `0x80073CFA`.  It remains on
disk but has **no service, task or process** and `WSAIFabricSvc` is Disabled.
Removing it would require an offline image edit and risks the CBS/shell
dependency graph.  It is therefore left installed but inert.

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

Observed after the change:

- AI task list: **empty**.
- AI processes: **none**.
- `WSAIFabricSvc`: **Stopped / Disabled**.
- AI packages: only `Microsoft.AIFabric.CBS.1.6` remains (protected framework).
- `Recall`: **DisabledWithPayloadRemoved**.
- Notepad `DisableAIFeatures=1`; Paint policies all `1`; Edge Copilot policies
  all `0`; `SettingsPageVisibility=hide:aicomponents`.
- Microsoft Copilot app: not installed, so no app to remove.

## Behaviour and caveats

- Edge, Paint and Notepad read their policies at process start.  **Restart
  Edge/Paint/Notepad** (or sign out) for the controls to take effect; Edge was
  running during the change.
- The AIFabric framework remains on disk.  It is not running and its service is
  disabled.  Physical removal requires an offline image edit.
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

# Allow CoreAI to be reinstalled: remove the EndOfLife key, then repair/reinstall
# through Windows Update or the Store.
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\EndOfLife' -Recurse |
  Where-Object { $_.PSChildName -like 'MicrosoftWindows.Client.CoreAI*' } |
  Remove-Item -Recurse -Force
```

AI scheduled tasks are normally recreated by Windows servicing; they can be
re-registered by the relevant Windows component if its feature is re-enabled.