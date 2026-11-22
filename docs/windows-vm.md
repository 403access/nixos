# Windows 11 VM on nixos

Verified **2026-11-20** and updated **2026-11-21** on NixOS 25.05 with
Windows 11 build 26300 (26H1). This is the operational record: what is
installed, how the helper CD is attached, and how to reconnect.

## Current guest

| Item | Value |
| --- | --- |
| libvirt domain | `win11-stock` |
| Disk | `/var/lib/libvirt/images/win11-stock.raw` (raw, 120 GiB) |
| Host storage | `/dev/nvme0n1p2` ext4, mounted at `/` (not `tank`) |
| Resources | 6 vCPU, 8 GiB, `host-passthrough`, Hyper-V enlightenments |
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

## Memory

The guest currently runs with **8 GiB** (reduced from 12 GiB). Windows 11 idle
at ~2.6 GB is normal and already low after the `lean` debloat; Defender, the
servicing stack and the driver set account for most of it. The number that
matters on the host is the full allocation: an 8 GiB guest holds ~8 GiB RSS
even when Windows touches only 2.6 GB.

Change the allocation from the NixOS host:

```bash
sudo ./scripts/vm-memory.sh 8 win11-stock
```

It shuts the guest down gracefully, sets `maxMemory` and `currentMemory` to
8 GiB, restarts it, and prints the result. Use 8 GiB for RDP/Office/browser
work; 12 GiB is only useful for heavy local applications.

The live process inventory and the reduction plan are in
[`windows-memory-analysis.md`](windows-memory-analysis.md): the guest commits
about 1.6 GiB while the host holds the full 8 GiB RSS, so the largest saving is
lowering the allocation (or adding a balloon) rather than killing processes.

Guest-side trims are optional and modest.  `trim-memory.bat` on the helper CD
removes OneDrive startup, Widgets, Recall and background apps; the aggressive
variant also disables Search indexing and SysMain.  For a full slim desktop,
run `minimal.bat` instead: it adds best-performance visuals, AI/web-search
removal, telemetry and background-task reduction, service trimming, Game DVR
shutdown and cache cleanup.  Defender, Windows Update and VBS stay enabled.

## Launcher (Everything)

The Windows 11 Start-menu host is disabled on this guest: `Win` and `Ctrl+Esc`
no longer open the tiles window.  Use **`Ctrl+Shift+E`** to toggle Everything,
or double-click the `Everything` shortcut on the desktop.  Everything starts at
logon, opens with an empty search box, and closes after launching an item.
`Ctrl+Alt+E` was deliberately not used because it is AltGr+E (`€`) on a German
layout.

The Start button is inert; use `Ctrl+Alt+Del` or `Win+X` for power options.
Everything is installed from the helper CD’s `apps.json`.  The exact commands,
WMI guard, and rollback are in
[`windows-memory-analysis.md`](windows-memory-analysis.md#12-replace-the-start-menu-with-everything-applied-2026-11-22).

## Automatic logon

RDP does **not** require it: the client authenticates and creates its own
session, even when the console sits at the lock screen.  Automatic logon is
only useful when programs inside Windows must start without anyone connecting.

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
Set-ItemProperty $k -Name AutoAdminLogon -Value '1'
Set-ItemProperty $k -Name DefaultUserName  -Value 'Windows-PC'
Set-ItemProperty $k -Name DefaultDomainName -Value $env:COMPUTERNAME
# DefaultPassword stores the password in cleartext; prefer netplwiz or
# Sysinternals Autologon, which keeps it in an LSA secret.
```

With autostart enabled, the chain becomes: host boots → libvirtd starts
`win11-stock` → Windows logs in → RDP connects to an already unlocked session.

Security: automatic logon removes the password prompt on the console.  Only
use it with a strong account password, and keep the guest reachable only over
loopback/SSH/Tailscale.

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

Current layout (verified 2026-11-21):

| Target | Media |
| --- | --- |
| `vda` | Windows disk |
| `sda` | empty |
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
- [`../scripts/windows/README.md`](../scripts/windows/README.md) — helper
  scripts, profiles, apps and offline hardening
- [`../install/README.md`](../install/README.md) — VM creation, Secure Boot
  limitation, boot order
- [`../SECURITY.md`](../SECURITY.md) — host exposures incl. the guest account
- [`../scripts/zfs-audit.sh`](../scripts/zfs-audit.sh) — host state