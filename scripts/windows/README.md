# Windows guest helper scripts

Run these inside the Windows 11 guest from a helper CD. They are all
double-click launchers that self-elevate through UAC and call PowerShell with
`-ExecutionPolicy Bypass`, so a machine policy that blocks scripts does not
matter.

| File | Purpose |
| --- | --- |
| `helper.bat` | Interactive menu for every action below; start here |
| `install-apps.bat` | Installs Everything, 7-Zip and Notepad++ from the CD's offline cache |
| `enable-rdp.bat` | Starts `TermService`, enables RDP, recreates the TCP 3389 rule, sets the network profile to Private |
| `disable-rdp.bat` | Disables RDP and removes the explicit `RDP 3389` firewall rule |
| `enable-ssh.bat` | Installs OpenSSH Server, starts `sshd`, opens TCP 22, sets PowerShell as the shell |
| `disable-ssh.bat` | Stops `sshd` and disables the SSH firewall rule |
| `create-restore-point.bat` | Enables System Restore and creates the `Before debloat` checkpoint (no rollback) |
| `debloat.bat` | Runs `windows/scripts/SetupComplete.ps1 -ProfileName lean` |
| `enable-autologon.bat` | Prompts for the account password and enables automatic logon |
| `disable-autologon.bat` | Removes automatic logon and the stored password |
| `trim-memory.bat` | Removes OneDrive startup, disables Widgets/Recall/background apps |
| `trim-memory-aggressive.bat` | Same, plus disables Search indexing and SysMain |
| `tune.bat` | Enables TRIM, sets High Performance, disables hibernation/Fast Startup |
| `trim-autostart.bat` | Disables non-essential Run/Startup-folder/packaged startup entries, with backup and restore |
| `trim-stock.bat` | Disables or uninstalls OneDrive, removes stock apps, disables stock services (including printing) |
| `apply-explorer-preferences.bat` | Shows hidden files, shows all extensions, opens This PC; optional protected files |
| `disable-visuals.bat` | Best-performance visuals: no animations, transparency, shadows, Aero Peek; per user |
| `disable-ai.bat` | Copilot, Recall, Click to Do, Widgets, taskbar Chat, web search, Start recommendations |
| `disable-telemetry.bat` | Minimum diagnostic data, no feedback prompts, activity history or advertising ID |
| `disable-scheduled-tasks.bat` | Disables telemetry, compatibility, disk-diagnostic, Maps and tips tasks |
| `optimize-services.bat` | Disables Maps/Fax/RemoteRegistry/RetailDemo/WMP sharing/Print Spooler; PcaSvc, WpcMonSvc, PhoneSvc to manual |
| `disable-gaming.bat` | Game DVR, Game Bar, Game Mode and Xbox services (breaks the Xbox app) |
| `cleanup.bat` | Temp, Delivery Optimization, thumbnails, WER and CBS logs; optional DISM/WU cache flags |
| `minimal.bat` | Runs the slim scripts above in order and writes a transcript |

## Main menu

`helper.bat` is the entry point. The main menu puts the common actions first:

1. **Create a restore point** — enables System Restore and checkpoints immediately
2. **System dashboard** — Windows build, memory, disk, restore points, tweak state, network
3. **Slim profile** — full run plus `-SkipGaming`, `-SkipCleanup` and Search/SysMain variants
4. **Performance & privacy** — visuals, AI, telemetry, tasks, services, gaming, memory, tune, debloat
5. **Cleanup & storage** — quick cleanup, dry run, Windows Update cache, DISM, Disk Cleanup
6. **Network & access** — enable/disable RDP, autologon, IP and listener info
7. **Tools & settings** — install to `C:\Tools\windows-helper`, logs, README, Settings, restart Explorer/Windows
8. **Apply my Explorer preferences** — hidden files, all extensions, open This PC
9. **Install apps** — Everything, 7-Zip and Notepad++ from the offline cache
10. **Startup apps (autostart)** — list, disable, remove or restore startup entries
11. **Stock apps & OneDrive** — disable/uninstall OneDrive, remove stock apps, disable services
12. **SSH server (terminal access)** — enable/disable OpenSSH, install a key, show commands

### Explorer preferences

Main menu 8 writes the current user's `Explorer\Advanced` values:

- `Hidden = 1` — show hidden files and folders
- `HideFileExt = 0` — show every file extension, including unknown types
- `LaunchTo = 1` — open File Explorer in This PC instead of Home

Protected operating system files stay hidden by default; the menu asks before
enabling `ShowSuperHidden`. It can restart Explorer immediately. These are
per-user settings, so run it once per account.

## Startup apps

Main menu 10, or `trim-autostart.bat`, empties the Windows autostart list:

- `HKCU` and `HKLM` Run keys, including `WOW6432Node`
- the per-user and common Startup folders
- packaged-app startup tasks (the entries under Settings > Startup)

Run values are **disabled** through `Explorer\StartupApproved`, exactly like
Task Manager, not deleted. Startup-folder shortcuts are moved to a backup.
Packaged tasks get `State = 1` (disabled by the user). The default keep list is
`ctfmon`, Windows Security, audio, touchpad and virtualization helpers;
`-Aggressive` disables everything except `ctfmon`.

Every change is backed up to
`%ProgramData%\WindowsSlim\autostart-backup\<timestamp>\` (`.reg` exports plus
`approved-state.json` and `uwp-startup.json`). Main menu 10 offers restore, and
`minimal.ps1` includes the startup cleanup as step 6.

```powershell
.\trim-autostart.ps1 -List
.\trim-autostart.ps1 -DryRun
.\trim-autostart.ps1                  # disable, keep the safe whitelist
.\trim-autostart.ps1 -Aggressive      # disable everything except ctfmon
.\trim-autostart.ps1 -Remove          # remove Run values after backup
.\trim-autostart.ps1 -Restore         # restore the latest backup
.\trim-autostart.ps1 -Keep 'MyApp*','SecurityHealth'
```

Use the Settings shortcut in the same menu for any packaged app that still
appears; sign out or reboot after restoring.

`Tools > Install helper to C:\Tools\windows-helper` copies every script and
adds a desktop shortcut, so the CD is only needed once. All menu actions are
logged to `%ProgramData%\WindowsSlim\windows-helper-menu.log`.

## Apps

Main menu 9, or `install-apps.bat`, installs from the CD:

| App | Version | Notes |
| --- | --- | --- |
| Everything | 1.4.1.1028 | Instant file and folder search |
| 7-Zip | 24.09 | Archive manager |
| Notepad++ | 8.9.9.1 | Text and code editor |

Installers live in `scripts/windows/apps/` and are intentionally ignored by
git (size and licensing). `apps.json` pins the file name, official URL,
SHA-256 and silent arguments. The CD build copies both the manifest and the
installers, so installation works offline.

To refresh the cache on the host or Mac:

```bash
cd scripts/windows
./fetch-apps.sh
```

PowerShell options:

```powershell
.\install-apps.ps1 -List
.\install-apps.ps1 -Verify
.\install-apps.ps1 -App everything,7zip
.\install-apps.ps1 -All
.\install-apps.ps1 -App everything -Download   # official URL fallback
.\install-apps.ps1 -App everything -Force      # reinstall
```

Every installer hash is verified before it runs. `Tools > Install helper to
C:\Tools` copies `apps/` too, so the installed helper keeps working without
the CD. To add an app, add an entry to `apps.json` and drop its installer into
`apps/`.

## Stock apps and OneDrive

Main menu 11, or `trim-stock.bat`, covers the stock consumer layer:

- **OneDrive: disable** — sets the sync policy, stops OneDrive/FileCoAuth, removes
  the Run entry and disables OneDrive scheduled tasks; local files stay.
- **OneDrive: uninstall** — runs the official `OneDriveSetup.exe /uninstall`,
  removes the `Microsoft.OneDriveSync` bridge and leaves local files in place.
- **Stock apps** — lean list (Bing apps, Xbox, Office Hub, Teams, Clipchamp,
  Solitaire, Maps, Alarms, etc.) or aggressive list, which also removes Store.
- **Stock services** — disables the lean list (telemetry, RetailDemo, Fax,
  RemoteRegistry, Maps, WMP sharing, wallet, Xbox, **Print Spooler and the
  print workflow/broker services**) or aggressive, which adds Search, SysMain,
  Bluetooth, Wi-Fi/hotspot, camera/scanner, location/sensors, smart cards,
  notifications, error reporting, diagnostics, network discovery, WinRM,
  VPN/IPsec, offline files, backup, gaming services and Delivery Optimization.

Services are only disabled, never deleted. Their original startup types are
saved to `%ProgramData%\WindowsSlim\stock-services.json` and can be restored
from the menu. Printing is disabled in the lean list; use **8) Restore service
startup types** or run `Set-Service Spooler -StartupType Automatic` if you ever
need it again. OneDrive state is saved to `onedrive-state.json`; the uninstaller
is not reversible from the script, but OneDrive can be downloaded again.

```powershell
.\trim-stock.ps1 -List
.\trim-stock.ps1 -OneDrive Disable -Apps Lean -Services Lean
.\trim-stock.ps1 -OneDrive Remove -Apps Aggressive -Services Aggressive
.\trim-stock.ps1 -RestoreServices
.\trim-stock.ps1 -RestoreOneDrive
```

App removal uses the supported AppX cmdlets and cannot be undone by the helper;
reinstall removed apps from the Store or the Windows image. `minimal.ps1`
applies the recommended combination as step 7 and accepts `-SkipStockApps`.

## SSH

Main menu 12, or `enable-ssh.bat`, installs the Windows OpenSSH Server
capability, starts `sshd`, opens TCP 22 and sets PowerShell as the default
shell. Password authentication stays enabled; pass `-PublicKeyPath` to install
an authorized key, then optionally `-DisablePasswordAuthentication`.

From the repo root on the Mac, jump through the NixOS host:

```bash
./scripts/win-ssh.sh
# or
ssh -J nixos@192.168.178.5 Windows-PC@192.168.122.50
```

The default guest address is the reserved libvirt lease `192.168.122.50`.
If it changes, pass it explicitly:

```bash
WINDOWS_SSH=Windows-PC@192.168.122.60 ./scripts/win-ssh.sh
```

Main menu 12 also shows the status/listener and connection command, installs a
public key, and can disable or uninstall OpenSSH. The SSH port is only reachable
through the host jump; it is not exposed on the LAN.

## Minimal profile

`minimal.bat` is the one-click combined run (main menu 3 → 1). It elevates
once and executes visuals, AI/suggestions, telemetry, scheduled tasks,
services, startup-app cleanup, stock-app/OneDrive cleanup, gaming and cleanup.
Create a restore point first (main menu 1 or `create-restore-point.bat`), then
reboot when it finishes. To roll back later, run `rstrui.exe` and pick the
`Before debloat` checkpoint; the batch file never restores anything itself.
The stock-service step also disables printing; use `-SkipStockApps` to keep the
stock apps and services.

Two details matter:

- `disable-visuals.ps1` writes `HKCU`, so sign in to each account and run it
  again for that profile. The other scripts are machine-wide.
- The gaming script disables the Xbox services. Steam and standalone games
  are unaffected; the Xbox app and Game Pass are not. Call
  `minimal.ps1 -SkipGaming` when you need those.

For the optional behaviour, call the PowerShell file directly from an
elevated prompt:

```powershell
.\minimal.ps1 -IncludeSearch -IncludeSysMain -ComponentCleanup
.\minimal.ps1 -SkipCleanup
.\minimal.ps1 -SkipGaming
.\minimal.ps1 -SkipStockApps
.\cleanup.ps1 -DryRun
.\cleanup.ps1 -WindowsUpdateCache -ComponentCleanup -ResetBase
```

`-ResetBase` makes installed updates non-removable, so leave it out unless you
need the space and accept that trade-off. The full log is written to
`%ProgramData%\WindowsSlim\windows-minimal.log`; the menu writes
`%ProgramData%\WindowsSlim\windows-helper-menu.log`.

## Build and insert the CD

These files are edited in the Mac checkout but the CD must be built on the
NixOS host, which has `xorriso` and the libvirt tools.  Two machines, two
steps:

On the **Mac**:

```bash
scp -r /Users/olivermolnar/Desktop/nixos/scripts/windows \
  nixos@192.168.178.5:~/Desktop/nixos/scripts/
```

On the **NixOS host**:

```bash
cd ~/Desktop/nixos/scripts/windows
ls                                        # the .bat/.ps1 files must be there
./fetch-apps.sh                           # only if apps/ is empty
./make-helper-iso.sh /tmp/windows-helper.iso

sudo virsh change-media win11-stock sdb --eject --live
sudo virsh change-media win11-stock sdb /tmp/windows-helper.iso --insert --live
```

`make-helper-iso.sh` also copies `windows/scripts/SetupComplete.ps1`,
`apps.json` and the `apps/` installers into the CD, so the debloat and app
installation actions are always available.

`trim-memory.bat` only reduces what Windows itself keeps resident. The host
still holds the full VM allocation; use `scripts/vm-memory.sh` for that.  If `insert` reports
`Cannot access storage file`, the ISO was not built (usually because the host
did not have the scripts yet) — run `ls` in the directory and rebuild.

The virtio-win CD can be replaced once the guest tools are installed.

Use a **new output filename** each time: an ISO that is inserted in a running
domain is open, and `xorriso` cannot overwrite it. `enable-rdp.bat` and the
others need CRLF line endings; the repository enforces that through
`.gitattributes`.

In Windows: File Explorer → the CD → F5 → double-click `helper.bat` → **Ja**
on UAC → choose an action. The individual `.bat` launchers still work if you
prefer one action at a time.
