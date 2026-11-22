# Microsoft Store removal

Guest: `win11-stock` — Windows 11 build 26300 (26H1) — applied
**2026-11-22**.

## What was present

| Component | State |
| --- | --- |
| `Microsoft.WindowsStore` 22610.1401.10.0 | Installed, `NonRemovable=False`, `SignatureKind=Store` |
| `Microsoft.StorePurchaseApp` 22609.1401.1.0 | Installed, `NonRemovable=False`, Store |
| `Microsoft.DesktopAppInstaller` 1.29.379.0 | Installed, **NonRemovable=True** — this is **winget**; kept |
| `Microsoft.Winget.Source` | Installed; kept |
| Store processes | None |
| `InstallService` (Microsoft Store Install Service) | Running / Manual |
| `ClipSVC`, `LicenseManager` | Running / Manual — kept for other Store apps |
| Store data | `Microsoft.WindowsStore` profile 0.6 MB; no `Windows Store` folder |
| Store shortcuts | None found |

Only Store and Store Purchase were removed; winget and the shared AppX/licence
services were deliberately kept.

## Removal

### 1. Remove the Store and purchase AppX packages

```powershell
foreach ($name in 'Microsoft.WindowsStore','Microsoft.StorePurchaseApp') {
  Get-AppxPackage $name | Remove-AppxPackage -AllUsers
  Get-AppxProvisionedPackage -Online |
    Where-Object { $_.PackageName -like "$name*" } |
    Remove-AppxProvisionedPackage -Online
}
```

Both returned **REMOVED_ALL**; verification reports `GONE` for both.

### 2. Disable the Store install service

```powershell
Set-Service InstallService -StartupType Disabled
Stop-Service InstallService -Force
```

`ClipSVC`, `LicenseManager`, `AppXSvc` and `StateRepository` are left as they
were — other Store apps (Photos, Calculator, etc.) still use them.

### 3. Disable only InstallService tasks

```powershell
Get-ScheduledTask -TaskPath '\Microsoft\Windows\InstallService\*' |
  ForEach-Object {
    Disable-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName
  }
```

Six tasks are now Disabled (`RestoreDevice`, `ScanForUpdates`,
`ScanForUpdatesAsUser`, `SmartRetry`, `WakeUpAndContinueUpdates`,
`WakeUpAndScanForUpdates`).

> A broad `TaskName -match 'Store'` filter also matched `CertStore` and
> `Restore`, briefly disabling `VerifiedPublisherCertStoreCheck`,
> `CloudRestore\Restore` and `InputSettingsRestoreDataAvailable`.  Those three
> were **re-enabled** and are `Ready` again.  Use the exact
> `\Microsoft\Windows\InstallService\*` path.

### 4. Remove data and shortcuts

```powershell
Remove-Item "$env:LOCALAPPDATA\Packages\Microsoft.WindowsStore_8wekyb3d8bbwe" -Recurse -Force
Remove-Item "$env:LOCALAPPDATA\Packages\Microsoft.StorePurchaseApp_8wekyb3d8bbwe" -Recurse -Force
Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows Store" -Recurse -Force
```

### 5. Block the Store from returning

```powershell
foreach ($root in 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore',
                  'HKCU:\Software\Policies\Microsoft\WindowsStore') {
  New-Item -Path $root -Force | Out-Null
  Set-ItemProperty $root -Name RemoveWindowsStore -Value 1 -Type DWord
}
```

This is the classic no-Store policy.  Windows Update may still re-offer Store
on a feature update; the policy keeps the app disabled if it returns.

## Verification

```powershell
foreach ($name in 'Microsoft.WindowsStore','Microsoft.StorePurchaseApp',
                  'Microsoft.DesktopAppInstaller','Microsoft.Winget.Source') {
  $p = Get-AppxPackage $name
  if ($p) { "PRESENT $($p.PackageFullName)" } else { "GONE    $name" }
}
Get-Service InstallService,ClipSVC,LicenseManager,AppXSvc,StateRepository |
  Select-Object Name,Status,StartType
Get-ScheduledTask -TaskPath '\Microsoft\Windows\InstallService\*' |
  Select-Object TaskPath,TaskName,State
winget.exe --version
```

Observed:

- `Microsoft.WindowsStore`: **GONE**
- `Microsoft.StorePurchaseApp`: **GONE**
- `Microsoft.DesktopAppInstaller`: **PRESENT** (winget)
- `Microsoft.Winget.Source`: **PRESENT**
- `InstallService`: **Stopped / Disabled**
- `ClipSVC`, `LicenseManager`, `AppXSvc`, `StateRepository`: unchanged
- Store install tasks: **Disabled**
- `winget --version`: **v1.29.380** — winget still works
- No Store or Store Purchase process remains
- `RemoveWindowsStore=1` set in HKLM and HKCU
- Guest snapshot after removal: 5.76 GB free, 99 processes, 2.50 GB working set

The RAM change is modest (Store was not running; `InstallService` was the main
resident piece).  The main wins are disk/provisioning and removing the background
update/install surface.

## Caveats

- Store apps already installed (Photos, Calculator, Notepad, etc.) are **not**
  removed.  They still have `ClipSVC`/`LicenseManager` and `AppXSvc`.
- Winget remains; `winget install` for Win32 packages is unaffected.  MSIX/Store
  source installs may need `InstallService`, which is now disabled.
- Windows Update/feature updates can restore Store; re-check after servicing and
  repeat if necessary.  The `RemoveWindowsStore` policy keeps it disabled.
- Windows Store app updates are no longer available through the Store UI.
- No reboot was required for the AppX removal; a later reboot will finalize any
  pending servicing.

## Rollback

```powershell
# Remove the no-Store policy
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name RemoveWindowsStore
Remove-ItemProperty 'HKCU:\Software\Policies\Microsoft\WindowsStore' -Name RemoveWindowsStore

# Re-enable the install service and its tasks
Set-Service InstallService -StartupType Manual
Start-Service InstallService
Get-ScheduledTask -TaskPath '\Microsoft\Windows\InstallService\*' |
  ForEach-Object { Enable-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName }

# Reinstall the Store through winget's msstore source (Store product ID)
winget.exe install --id 9WZDNCRFJBMP -e --source msstore
```

The Store and Store Purchase packages can also be restored from Windows
servicing/feature-update media if the Store package is unavailable.