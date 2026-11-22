# Microsoft Edge removal

Guest: `win11-stock` — Windows 11 build 26300 (26H1) — applied
**2026-11-22**.  Edge was the largest remaining process at ~480 MiB across
seven processes.

## What was present

| Item | Value |
| --- | --- |
| Edge version | 158.0.4370.33 |
| Installer | `C:\Program Files (x86)\Microsoft\Edge\Application\158.0.4370.33\Installer\setup.exe` |
| AppX | `Microsoft.MicrosoftEdge.Stable` — `NonRemovable=False`, `SignatureKind=Developer` |
| Update services | `edgeupdate` (Stopped/Automatic), `edgeupdatem` (Stopped/Manual) |
| Update tasks | `MicrosoftEdgeUpdateTaskMachineCore{07AB…}`, `…UA{4915…}` |
| User profile | `%LOCALAPPDATA%\Microsoft\Edge\User Data` — **241.9 MB** |
| WebView2 | separate `Microsoft Edge WebView2-Laufzeit` 158.0.4370.33 (kept) |

## Removal

### 1. Back up the profile

```powershell
$src = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
$backup = 'C:\ProgramData\WindowsSlim\backup\Edge-UserData'
New-Item -Path $backup -ItemType Directory -Force | Out-Null
robocopy $src $backup /E /R:1 /W:1
```

The backup is 241.9 MB and preserves bookmarks, history and local profile data.
The live profile is removed afterwards.

### 2. Uninstall Edge

Stop the browser first, then run the official system-level uninstaller:

```powershell
Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force
$setup = Get-ChildItem 'C:\Program Files (x86)\Microsoft\Edge\Application' -Recurse -Filter setup.exe |
  Where-Object { $_.FullName -match 'Installer' } | Sort-Object FullName -Descending | Select-Object -First 1
Start-Process -FilePath $setup.FullName -ArgumentList `
  '--uninstall','--msedge','--channel=stable','--system-level','--verbose-logging','--force-uninstall' `
  -Wait
```

The installer returned **532**, but its result was verified independently:
`msedge.exe` and `C:\Program Files (x86)\Microsoft\Edge` are gone.  Do not rely
on the exit code alone; verify the paths below.

### 3. Remove the AppX registration

`Microsoft.MicrosoftEdge.Stable` is not marked NonRemovable, so this succeeded:

```powershell
$pkg = Get-AppxPackage Microsoft.MicrosoftEdge.Stable
Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers
```

### 4. Remove Edge Update tasks and services

```powershell
Get-ScheduledTask | Where-Object { $_.TaskName -match 'EdgeUpdate|MicrosoftEdge' } |
  ForEach-Object { Unregister-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName -Confirm:$false }
foreach ($s in 'edgeupdate','edgeupdatem') {
  if (Get-Service $s -ErrorAction SilentlyContinue) {
    Stop-Service $s -Force
    sc.exe config $s start= disabled
    sc.exe delete $s
  }
}
```

### 5. Remove shortcuts and live data

```powershell
Get-ChildItem 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs',
              'C:\Users\Windows-PC\Desktop',
              'C:\Users\Windows-PC\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar' `
  -Filter '*Edge*' -Recurse |
  Remove-Item -Force
Remove-Item "$env:LOCALAPPDATA\Microsoft\Edge" -Recurse -Force
Remove-Item "$env:APPDATA\Microsoft\Edge" -Recurse -Force
Remove-Item 'C:\Program Files (x86)\Microsoft\Edge' -Recurse -Force
```

## Verification

```powershell
Test-Path 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
Get-AppxPackage Microsoft.MicrosoftEdge.Stable
Get-Process msedge
Get-Service edgeupdate,edgeupdatem
Get-ScheduledTask | Where-Object { $_.TaskName -match 'EdgeUpdate|MicrosoftEdge' }
Test-Path "$env:LOCALAPPDATA\Microsoft\Edge"
Test-Path 'C:\ProgramData\WindowsSlim\backup\Edge-UserData'
```

Observed:

- `msedge.exe` and the Edge directory: **gone**.
- Edge AppX: **removed**.
- Edge processes: **none**.
- `edgeupdate`/`edgeupdatem`: **deleted**.
- Edge update tasks: **removed**.
- Live profile: **removed**; backup present.
- WebView2 runtime: **kept** because it is a shared component used by other
  applications; it is not the Edge browser.
- Chrome and Task Manager were running during the final snapshot (your apps),
  so the measured free-memory delta is partly masked.  Edge itself accounted
  for roughly **480 MiB**.

## Caveats

- Windows Update may offer or reinstall Edge as a Windows component.  If it
  returns, repeat the uninstall and remove its AppX/update tasks again.
- The Edge profile backup is at
  `C:\ProgramData\WindowsSlim\backup\Edge-UserData` (241.9 MB).  Delete it if you
  do not need the bookmarks/history.
- WebView2 remains installed under
  `C:\Program Files (x86)\Microsoft\EdgeWebView`; no WebView2 process was
  running.  Removing it would affect applications that embed WebView2.
- There is no Edge browser after this; Chrome was installed/opened separately.
- Edge policy keys under `HKLM\SOFTWARE\Policies\Microsoft\Edge` are left in
  place.  They only apply to Edge if it is ever reinstalled (and keep its AI
  surfaces off).

## Rollback

Reinstall Edge from Microsoft’s official installer (or a pinned offline
installer), then restore the profile:

```powershell
# after Edge is reinstalled and closed:
Remove-Item "$env:LOCALAPPDATA\Microsoft\Edge\User Data" -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item 'C:\ProgramData\WindowsSlim\backup\Edge-UserData' `
  "$env:LOCALAPPDATA\Microsoft\Edge\User Data" -Recurse -Force
```

The Edge Update tasks/services recreate themselves on the next Edge install.