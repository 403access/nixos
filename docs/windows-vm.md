# Windows 11 VM on nixos

The live, offline-image and VM operations in this guide are also exposed by the
[Image Studio MCP server](image-studio.md) (`image-studio/`). Use it for
scripted trims, offline hive edits and image bundle export/import.

Verified **2026-11-20** and updated **2026-11-21** on NixOS 25.05 with
Windows 11 build 26300 (26H1). This is the operational record: what is
installed, how the helper CD is attached, and how to reconnect.

## Current guest

| Item | Value |
| --- | --- |
| libvirt domain | `win11-stock` |
| Disk | `/var/lib/libvirt/images/win11-stock.raw` (raw, 120 GiB) |
| Host storage | `/dev/nvme0n1p2` ext4, mounted at `/` (not `tank`) |
| Resources | 2 vCPU, 4 GiB, `host-passthrough`, Hyper-V enlightenments |
| Devices | virtio-blk, virtio-net, vTPM 2.0, virtio-gpu, SATA CD |
| Firmware | UEFI (OVMF), **Secure Boot off** — see the 2023 CA note |
| Local account | `Windows-PC` (password kept out of this repo) |
| Source media | official Windows 11 ISO, build 26300 |
| Guest lease | `192.168.122.50/24` (reserved libvirt lease) |
| Autostart | enabled |
| CD layout | `vda` Windows disk; `sda` empty; `sdb` helper ISO |
| Helper ISO | `/home/nixos/Downloads/windows-helper.iso` |

`nixos` is in the host's `libvirtd` group, so the operational commands use
`virsh -c qemu:///system`. Plain `virsh` connects to the per-user session and
will report `failed to get domain 'win11-stock'`; `sudo virsh` also works.

The Windows image came from the **stock** ISO, not from
`windows/out/Win11-lean-*.iso`. The slim image's baked autounattend fails
OOBE on 26300 (`CUnattendManager::Initialize 0x80070490`,
`BCD ... c000000f`), even with Secure Boot off. Install Windows first, then
apply the debloat as a normal first-logon script (see *Debloat* below).

## Install notes

- At the disk step, load `viostor\w11\amd64` from the virtio-win CD.
- After the first reboot, **eject the install ISO**; the no-prompt EFI boot
  image otherwise starts Setup again in a loop:
  `virsh -c qemu:///system change-media win11-stock sda --eject --live`.
- Install `virtio-win-guest-tools.exe` from the virtio-win CD for the NIC,
  graphics and balloon drivers.
- Enable TRIM as Administrator:
  `fsutil behavior set DisableDeleteNotify 0`.
- Secure Boot is off because Windows 11 24H2+ boot managers are signed with
  the Microsoft UEFI CA 2023, which the OVMF vars template used here does not
  trust. TPM 2.0 remains enabled.

## Autostart

Autostart is **enabled** for `win11-stock`. Check it with:

```bash
virsh -c qemu:///system dominfo win11-stock | grep Autostart  # enable
virsh -c qemu:///system net-info default | grep Autostart     # network too
```

`dominfo` is the authoritative check. On NixOS libvirt keeps its config under
`/var/lib/libvirt`, not `/etc`; locate the autostart link with:

```bash
sudo find /var/lib/libvirt /etc/libvirt -maxdepth 5 \
  \( -name autostart -o -name 'win11-stock.xml' \) -print
```

Autostart is applied when libvirtd starts, so it takes effect on the next host
boot and does not need a reboot to confirm the setting.

`virsh -c qemu:///system autostart --disable win11-stock` reverts it. The
default libvirt network is started by the NixOS module at boot, so the guest
gets its lease without manual steps.

## CPU allocation and host priority

The VM runs with **8 vCPUs** (1 socket × 4 cores × 2 threads = every host
thread) and **8 GB** RAM. It may use the whole machine while the host is idle.

Host work always wins under contention, without a hard cap:

- `machine.slice` is given `CPUWeight=10` and `IOWeight=10` through
  `systemd.slices.machine` in `configuration.nix`, against the default weight
  100 of `user.slice` and `system.slice`.
- libvirt also sets the domain's `cputune` to `<shares>256</shares>`.

Weights only matter when the host is busy. During a compile or other host load
the VM yields; when the host is idle the VM still gets every free cycle.

Verify the settings:

```bash
virsh -c qemu:///system dumpxml win11-stock \
  | grep -E "<vcpu|<topology|<shares"
systemctl show machine.slice -p CPUWeight -p IOWeight
cat /sys/fs/cgroup/machine.slice/cpu.weight
```

## Memory

The guest currently runs with **4 GiB** (reduced from 12 GiB, then 8 GiB, then
4 GiB on 2026-11-22). Windows uses ~1.24 GiB at idle and reports **2,819 MiB
free**. Host QEMU RSS is **4.10 GiB** with the cap alone and **~2.0 GiB at idle
with KSM zero-page merging**. Defender, the servicing stack and the driver set
account for most of the idle footprint. 4 GiB is enough for RDP, Chrome, SSH and
moderate FL Studio projects; use 6 GiB if you routinely load large sample
libraries.

Change the allocation from the NixOS host:

```bash
sudo ./scripts/vm-memory.sh 4 win11-stock
```

It shuts the guest down gracefully, sets `maxMemory` and `currentMemory` to
4 GiB, restarts it, and prints the result.

The live process inventory and the reduction plan are in
[`windows-memory-analysis.md`](windows-memory-analysis.md): the guest commits
about 1.2 GiB at idle, so the 4 GiB cap leaves ~2.7 GiB for applications.
Host-side KSM with `use_zero_pages=1` holds QEMU RSS near 2.0 GiB at idle. It
is persisted by the `ksm-zero-pages` unit in the host's
`/etc/nixos/configuration.nix`; the pre-change config is at
`/root/configuration.nix.bak-ksm-2026-11-22`.

Guest-side trims are optional and modest.  `trim-memory.bat` on the helper CD
removes OneDrive startup, Widgets, Recall and background apps; the aggressive
variant also disables Search indexing and SysMain.  For a full slim desktop,
run `minimal.bat` instead: it adds best-performance visuals, AI/web-search
removal, telemetry and background-task reduction, service trimming, Game DVR
shutdown and cache cleanup.  The helper script leaves Defender, Windows Update
and VBS enabled; on this guest Defender/VBS were later disabled, and the update
services are disabled between patch days.

## Launcher (PowerToys Run)

The Windows 11 Start-menu host is disabled on this guest: `Win` and `Ctrl+Esc`
no longer open the tiles window.  Press **`Alt+Space`** to open PowerToys Run
(no account, no cloud dependency).  PowerToys starts at logon through its own
`\PowerToys\Autorun for Windows-PC` task; every module except Run is disabled.
The duplicate `\WindowsSlim\StartPowerToys` task was removed.  Everything was
measured first but was only a file search window, so it was removed.

The Start button is inert; use `Ctrl+Alt+Del` or `Win+X` for power options.
PowerToys Run idles as low as ~17 MiB (8 MiB host + 8 MiB launcher), typically
80–105 MiB after use, rising to ~200 MiB while the UI is warm. At idle it is far
lighter than the Start menu it replaced; while warm it costs about 43 MiB more.  The exact install,
module-trimming, WMI guard and rollback are in
[`windows-memory-analysis.md`](windows-memory-analysis.md#12-replace-the-start-menu-with-powertoys-run-applied-2026-11-22).

## Printer and further trims

Printing is fully disabled: no printers, drivers or ports remain, the print
services and the `Printing-Foundation` / Print-to-PDF / Internet Printing
features are off, and `PrintWorkflowUserSvc` is disabled.  Re-enable the Windows
Features if printing is ever needed.  The second trim also disabled WorkFolders,
WCF, SMB Direct and the guest-side RDP client (the RDP **server** is untouched),
and the guest now has **99 disabled services**, including the update stack
(`DoSvc`, `UsoSvc`, `wuauserv`) and `TokenBroker`.  Edge, FL Studio,
audio and PowerToys were left alone.  Details and the next candidates are in
[`windows-memory-analysis.md`](windows-memory-analysis.md#printer-features-services-and-apps-2026-11-22).

OneDrive is fully removed: the per-user engine (578 MB), the 85.6 MB
`OneDriveSetup.exe` stub, and the LocalService `OneDriveSetup` Run value are
gone.  The empty `C:\Users\Windows-PC\OneDrive` folder remains but contains no
data, and no sync client starts at logon.

## Browser

Microsoft Edge was removed (executable, AppX, update services/tasks, shortcuts,
and live profile).  The profile is backed up at
`C:\ProgramData\WindowsSlim\backup\Edge-UserData` (241.9 MB).  Chrome is
installed/used instead.  The dead Edge auto-launch Run value and the stale
Edge/Edge Update uninstall keys were also removed; only the WebView2 entry
remains.  The shared WebView2 runtime stays at
`C:\Program Files (x86)\Microsoft\EdgeWebView` because other applications may
embed it.  Windows Update may offer Edge again; see
[`windows-edge-removal.md`](windows-edge-removal.md).

## Microsoft Store

Microsoft Store and Store Purchase were removed; `InstallService` is Disabled
and its six Store update tasks are Disabled.  The classic no-Store policy
(`RemoveWindowsStore=1`) is set in HKLM and HKCU.  **Winget is retained**
(`Microsoft.DesktopAppInstaller` and `Microsoft.Winget.Source`), and
`ClipSVC`/`LicenseManager` remain for the other Store apps.  Windows Update may
re-offer Store on a feature update; see
[`windows-store-removal.md`](windows-store-removal.md).

## AI components

Copilot/Recall/Click-to-Do policies are off, the `WindowsAI` scheduled tasks
were removed, and `WSAIFabricSvc` is Disabled.  `MicrosoftWindows.Client.CoreAI`
and `Microsoft.AIFabric.CBS.1.6` were removed online, but CBS restored them on
the next boot; they were then removed **offline** (payloads, WinSxS components,
task folder and AppX registration), which persisted and passed
`DISM /CheckHealth`.  No AI package, process, task or service remains.  Backups
are in `C:\ProgramData\WindowsSlim\backup\AIFabric-CBS-1.6` and on the host in
`/root/ai-offline-backup-2026-11-22`.  Edge, Paint and Notepad AI controls are
policy-disabled; restart those apps for the policies to take effect.  See
[`windows-ai-removal.md`](windows-ai-removal.md).

## RDP session limits

The RDP **server** is kept, but stale sessions are now bounded:

```powershell
$k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
Set-ItemProperty $k -Name MaxDisconnectionTime   -Value 300000  -Type DWord # 5 min
Set-ItemProperty $k -Name MaxIdleTime            -Value 1800000 -Type DWord # 30 min
Set-ItemProperty $k -Name fResetBroken           -Value 0       -Type DWord
Set-ItemProperty $k -Name fSingleSessionPerUser  -Value 0       -Type DWord
```

Closing the client without signing out logs the session off after five minutes.
The console is **not** forced to log back in while RDP is in use; that policy
fights the RDP takeover and causes session churn. Reconnect with RDP, or reboot
to get the boot auto-logon. Unsaved work in the disconnected session is lost, so
sign out (or save) before disconnecting. Set the values back to `0` to restore
the old behaviour.

## Recovery removed

WinRE, the 911 MB recovery partition, System Restore and shadow copies are
removed; `C:` was extended to 119.79 GB. Recovery is by redeploying a clean VM
and restoring data from the host, not by WinRE/Reset.

The active `win11-stock` is a promoted clone of the cleaned disk (original
UUID/MAC, 4 GiB, 2 vCPU); `win11-stock-old` is a cold fallback with autostart
disabled. See [`windows-recovery-removal.md`](windows-recovery-removal.md) for
the exact state, GPT backup, activation note and the
`install/windows-vm-create.sh` deploy command.

## Automatic logon

**Enabled 2026-11-22.** The console logs in as `Windows-VM\Windows-PC` at boot
and again after a logoff. Current Winlogon values:

| Value | State |
| --- | --- |
| `AutoAdminLogon` | `1` |
| `DefaultUserName` | `Windows-PC` |
| `DefaultDomainName` | `WINDOWS-VM` |
| `ForceAutoLogon` | unset/`0` |
| `DefaultPassword` | present (value not recorded here) |

`ForceAutoLogon` is deliberately **unset**. Setting it to `1` makes the console
re-login after an RDP disconnect, which can immediately kick the RDP session.
`AutoAdminLogon` still logs the console in at boot.

RDP does not require auto-logon for authentication, but the VM does need a
logged-in console session for PowerToys Run and for FL Studio or other work that
should run without an RDP client attached.

### Windows guest

Either run `control userpasswords2` (or `netplwiz`) and clear **“Users must
enter a user name and password to use this computer”**, or use the helper CD:

- `enable-autologon.bat` — prompts for the account password and writes the
  Winlogon values
- `disable-autologon.bat` — reverts it and removes the stored password

The prompt is masked; the password is still stored by Windows (Winlogon
registry, or an LSA secret with Sysinternals Autologon) so the account can be
logged in at boot.

The equivalent registry form, for reference:

```powershell
$k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $k -Name AutoAdminLogon  -Value '1'
Set-ItemProperty $k -Name DefaultUserName -Value 'Windows-PC'
Set-ItemProperty $k -Name DefaultDomainName -Value $env:COMPUTERNAME
# Do not set ForceAutoLogon=1 if RDP is used; it races the RDP session.
# DefaultPassword stores the password in cleartext; prefer netplwiz or
# Sysinternals Autologon, which keeps it in an LSA secret.
```

Verify without printing the password:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' |
  Select-Object AutoAdminLogon,DefaultUserName,DefaultDomainName,ForceAutoLogon
qwinsta
```

With autostart enabled, the chain becomes: host boots → libvirtd starts
`win11-stock` → Windows logs in → RDP connects to an already unlocked session.
After an RDP timeout or manual sign-out the console stays logged off; reconnect
with RDP, or reboot to get the boot auto-logon.

To disable it, run `disable-autologon.bat` and also clear the forced value:

```powershell
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
  -Name AutoAdminLogon,DefaultPassword,ForceAutoLogon -ErrorAction SilentlyContinue
```

Security: automatic logon removes the password prompt on the console and stores
the password recoverably. Only use it with a strong account password, and keep
the guest reachable only over loopback/SSH/Tailscale. The password is not stored
in this repository.

### NixOS host (if meant instead)

For the host desktop, the display manager can auto-login too:

```nix
services.displayManager.autoLogin = {
  enable = true;
  user = "nixos";
};
```

The Hyprland wrapper already sets this; the XFCE/plasma profiles use lightdm
or SDDM and honour the same option.

## Helper CD

The helper CD is built from `scripts/windows/` on the NixOS host. It includes
`helper.bat`, every individual `.bat` launcher, `SetupComplete.ps1`, the
`verify-minimal` scripts, and the offline app installers.

### Build, mount and replace

On the Mac, sync the helper directory to the host. The host copy lives under
`~/Desktop/nixos`, not `/etc/nixos`:

```bash
scp -r /Users/olivermolnar/Desktop/nixos/scripts/windows \
  nixos@192.168.178.5:~/Desktop/nixos/scripts/
```

On the NixOS host:

```bash
cd ~/Desktop/nixos/scripts/windows
./fetch-apps.sh          # only if apps/ is empty
./make-helper-iso.sh /home/nixos/Downloads/windows-helper-new.iso
```

Use a fresh scratch filename. An ISO that is already inserted is open, and
`xorriso` cannot overwrite it. Eject the old CD, move the new ISO over the
stable path, then insert it live and save the same source in the domain config:

```bash
virsh -c qemu:///system change-media win11-stock sdb --eject --live
mv -f /home/nixos/Downloads/windows-helper-new.iso \
  /home/nixos/Downloads/windows-helper.iso
virsh -c qemu:///system change-media win11-stock sdb \
  /home/nixos/Downloads/windows-helper.iso --insert --live

virsh -c qemu:///system change-media win11-stock sdb --eject --config
virsh -c qemu:///system change-media win11-stock sdb \
  /home/nixos/Downloads/windows-helper.iso --insert --config
```

Current layout (verified 2026-11-23):

| Target | Media |
| --- | --- |
| `vda` | Windows disk |
| `sda` | VIRTIO guest-tools ISO |
| `sdb` | helper ISO |

The stable helper ISO is
`/home/nixos/Downloads/windows-helper.iso`. To update it, build a new file,
eject `sdb`, move the new file over the stable path, then insert it again. Do
not overwrite an ISO while it is attached.

Verify from the host:

```bash
virsh -c qemu:///system domblklist win11-stock
virsh -c qemu:///system dumpxml --inactive win11-stock | grep -A3 cdrom
```

In Windows: open **This PC**, press **F5**, and open the CD volume
**ISOIMAGE**. Start with `helper.bat` and approve UAC. If the drive does not
appear, reboot the guest or use **Device Manager → Scan for hardware
changes**.

### Enable RDP from the CD

Double-click `enable-rdp.bat`, or open **Changes → Network & access** in
`helper.bat`. It self-elevates, starts `TermService`, enables RDP, creates the
TCP 3389 firewall rule, sets the network profile to Private, and prints the
edition, users and listener.

Two known quirks:

- `Get-NetFirewallRule -DisplayGroup 'Remote Desktop'` returns nothing on a
  German system (the group is `Remotedesktop`). Use the explicit port rule,
  which is language-independent.
- `virsh attach-disk ... --type cdrom` can fail with
  *“No more available PCI slots”*. Replace the existing SATA CD with
  `change-media` instead.

## Display resolution

The host HDMI output is 1920×1080. The guest keeps its own framebuffer mode; with
virtio-gpu and no guest agent it defaults to **1280×800**, and a fullscreen
viewer alone does not change it.

- `start-vm` opens `virt-viewer` with `--full-screen --auto-resize=always`.
  Auto-resize only takes effect once the virtio-win guest tools (the SPICE
  agent) are installed in Windows.
- Install `virtio-win-guest-tools.exe` from the VIRTIO CD (below), reboot
  Windows, then set **Settings → Display → 1920×1080** — or let the fullscreen
  viewer resize the guest.
- The domain also carries the preferred mode for new boots:

  ```xml
  <video>
    <model type='virtio' heads='1' primary='yes'>
      <resolution x='1920' y='1080'/>
    </model>
  </video>
  ```

  Video changes need a full domain restart (`virsh shutdown win11-stock` then
  `virsh start win11-stock`), not just a reboot inside Windows.

### VIRTIO guest-tools CD

`virtio-win` keeps the installer in the Nix store. Build a CD with the
installer, both MSIs and the certificate — **with Joliet**, otherwise Windows
shows 8.3 names such as `VIRTIO_W.EXE` instead of
`virtio-win-guest-tools.exe`:

```bash
V=$(ls -d /nix/store/*-virtio-win-0.1.271-1 | head -1)
rm -rf /tmp/virtio-tools && mkdir -p /tmp/virtio-tools
cp "$V"/virtio-win-guest-tools.exe "$V"/virtio-win-gt-x64.msi \
   "$V"/virtio-win-gt-x86.msi /tmp/virtio-tools/
cp -r "$V"/cert /tmp/virtio-tools/
xorriso -as mkisofs -J -R -joliet-long -V VIRTIO \
  -o /home/nixos/Downloads/virtio-win-tools.iso /tmp/virtio-tools
```

Insert it into the empty `sda` drive (and persist it in the domain config):

```bash
virsh -c qemu:///system change-media win11-stock sda --eject
virsh -c qemu:///system change-media win11-stock sda \
  /home/nixos/Downloads/virtio-win-tools.iso --insert
virsh -c qemu:///system change-media win11-stock sda --eject --config
virsh -c qemu:///system change-media win11-stock sda \
  /home/nixos/Downloads/virtio-win-tools.iso --insert --config
```

If the guest instead shows only `VIRTIO_W.EXE`, the ISO was built without
`-J`; rebuild it and eject/reinsert the media.

## Connecting from macOS

The guest is behind libvirt NAT (`192.168.122.0/24`), so the Mac cannot reach
it directly. `192.168.178.5:3389` is the host's xrdp, not Windows.

```bash
# on the NixOS host, note the guest address
virsh -c qemu:///system domifaddr win11-stock --source lease

# on the Mac, keep this open (current reserved lease: .50)
ssh -N -L 13389:192.168.122.50:3389 nixos@192.168.178.5
```

Then in **Windows App** (formerly Microsoft Remote Desktop):

- PC name: `localhost:13389`
- User: `.\Windows-PC`
- Password: from the password manager

Check the tunnel from the Mac with `nc -vz localhost 13389`; it must report
success before the client connects.

### Pin the guest address

DHCP can move the address after a reboot. Reserve it (get the MAC from
`virsh -c qemu:///system dumpxml win11-stock`):

```bash
virsh -c qemu:///system net-update default add ip-dhcp-host \
  '<host mac="52:54:00:b6:38:f5" name="win11-stock" ip="192.168.122.50"/>' \
  --live --config
```

After a guest reboot the tunnel becomes
`ssh -N -L 13389:192.168.122.50:3389 nixos@192.168.178.5`.

## RDP console session (alternative to SPICE)

The normal physical-console path is `start-vm` (virt-viewer/SPICE). An optional
RDP path keeps the VM on the HDMI monitor but avoids the SPICE display pipeline:

```bash
start-vm-rdp
```

It resolves the guest address, checks TCP 3389, and runs `xfreerdp` with
`+admin +dynamic-resolution /f /sound /clipboard` against the **console
session** — the same session the physical console would show. FreeRDP draws the
cursor client-side, so pointer motion is immediate; the rest of the screen still
goes through RDP encoding, which is generally faster than SPICE.

- Log in as `Windows-PC` (local account on `Windows-VM`) when xfreerdp prompts;
  the password is not stored.
- Input for this path goes through **NixOS X**, not the Windows InputLeap
  client: keep the Mac on the **nixos** screen (`Ctrl+Option+1`) or use the
  Logitech receiver on the host. Do **not** switch the Mac to `Windows-VM`
  while RDP is open; InputLeap would fight the RDP session.
- Audio is redirected by FreeRDP to the host’s default sink, so the AirPods
  bridge still works.
- Close the SPICE viewer first (or use Alt+Tab); both can be open for comparison.
- `start-vm` stays the default; the SPICE path is unchanged.

## SSH (terminal only)

The guest does not enable OpenSSH by default. Run the helper CD and choose
**Changes → Network & access → Enable SSH server**, or double-click
`enable-ssh.bat`. It installs the bundled Win32-OpenSSH server (use
`-Method Capability` for the Windows optional feature), starts `sshd`, opens
TCP 22 and sets PowerShell as the default shell.

From the repo root on the Mac, use a jump through the host:

```bash
./scripts/win-ssh.sh
# equivalent:
ssh -J nixos@192.168.178.5 Windows-PC@192.168.122.50
```

The default guest address is the reserved lease `192.168.122.50`. If DHCP moved
it, check `virsh -c qemu:///system domifaddr win11-stock --source lease` on the
host and override it:

```bash
WINDOWS_SSH=Windows-PC@192.168.122.60 ./scripts/win-ssh.sh
```

Password login uses the Windows account password. For key login, copy the
public key somewhere the guest can read (for example `C:\Tools\id_ed25519.pub`),
then use **Changes → Network & access → SSH: install public key...**. To
disable password authentication afterwards,
run:

```powershell
.\enable-ssh.ps1 -PublicKeyPath C:\Tools\id_ed25519.pub -DisablePasswordAuthentication
```

`disable-ssh.bat` stops the service and disables the firewall rule;
**Changes → Network & access → Uninstall OpenSSH Server** removes the capability. SSH is only reachable through the host jump, not from
the LAN directly.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Setup loops after install | Install ISO still attached; eject `sda` |
| Disk list empty in Setup | Load `viostor\w11\amd64` from the virtio-win CD |
| `failed to get domain 'win11-stock'` | Use `virsh -c qemu:///system`; plain `virsh` uses the session URI |
| Helper CD missing in Windows | Check `domblklist`; insert on `sdb`; `sda` is empty by design |
| `Get-NetFirewallRule -DisplayGroup` finds nothing | German localization; use the port rule |
| Script blocked by execution policy | Run `enable-rdp.bat`, not the `.ps1` |
| `xorriso ... Permission denied` | ISO still inserted; eject `sdb` or build to a new filename |
| RDP `Access denied` | Wrong user form; use `COMPUTER\user` from `whoami` |
| RDP not offered | Windows edition is Home; hosting needs Pro |

## Debloat

`windows/scripts/SetupComplete.ps1` is a normal PowerShell script. Copy it
into the guest (helper CD or the Samba share) and run as Administrator:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\SetupComplete.ps1 -ProfileName lean
```

It removes consumer AppX packages, disables telemetry services and scheduled
tasks, and leaves Store, Defender and Windows Update working. For a full
inventory of the guest's scheduled tasks, what each one does, and which are
safe to disable, see [windows-scheduled-tasks.md](windows-scheduled-tasks.md).

## Verify the slim state

The current helper CD ships `verify-minimal.bat`, a read-only check for the
hardened Search/Defender state. If your CD predates 2026-11-21, rebuild it
with `make-helper-iso.sh`; older ISOs may not include this file.

```powershell
.\verify-minimal.bat
```

It reports `PASS`/`FAIL` for the Search service and files, Defender processes,
active binaries, policies, IFEO blocks and scheduled tasks, and exits `1` if
anything regressed. `-Json` produces machine-readable output.

## Offline Search/Defender hardening

When Windows resets a service start type or restores a Defender binary, patch
the hives with the VM shut down instead of fighting the live system:

```bash
sudo ./scripts/windows/offline/apply.sh --mode all
sudo ./scripts/windows/offline/apply.sh --mode defender --domain win11-stock
```

The script shuts the domain down, mounts the raw disk with `qemu-nbd`, backs up
`SYSTEM` and `SOFTWARE` under `/root`, applies the Search/Defender changes,
verifies them, and starts the VM again. `--mode search` only touches
`WSearch`/the search UI files.

`--hive-dir` runs the merge/verify code against a pair of hive files without
root, a VM or a disk; the test suite uses that mode.

## Tests

```bash
./scripts/windows/tests/run-tests.sh
```

The suite covers the Search and Defender helpers, the profile presets, the
service/app lists, the tabbed menu wiring, packaging, and the offline hive
patch. See [`../scripts/windows/tests/README.md`](../scripts/windows/tests/README.md)
for the individual files and the optional real-hive test.

## See also

- [`windows-scheduled-tasks.md`](windows-scheduled-tasks.md) — scheduled-task
  inventory and which tasks are safe to disable
- [`windows-memory-analysis.md`](windows-memory-analysis.md) — live process
  inventory and the prioritized RAM reduction plan
- [`windows-vm-inventory-commands.md`](windows-vm-inventory-commands.md) —
  host→guest commands for processes, services, apps, tasks and devices
- [`windows-ai-removal.md`](windows-ai-removal.md) — removed Microsoft AI
  services, apps, tasks and policies
- [`windows-edge-removal.md`](windows-edge-removal.md) — Edge uninstall,
  profile backup and WebView2 note
- [`windows-store-removal.md`](windows-store-removal.md) — Store removal,
  winget retention and rollback
- [`../scripts/windows/README.md`](../scripts/windows/README.md) — helper
  scripts, profiles, apps and offline hardening
- [`../install/README.md`](../install/README.md) — VM creation, Secure Boot
  limitation, boot order
- [`../SECURITY.md`](../SECURITY.md) — host exposures incl. the guest account
- [`../scripts/zfs-audit.sh`](../scripts/zfs-audit.sh) — host state