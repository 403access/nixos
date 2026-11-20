# Windows 11 VM on nixos

Verified working **2026-11-20** on NixOS 25.05 with Windows 11 build 26300
(26H1). This is the operational record: what is installed, how RDP was turned
on, and how to reconnect.

## Current guest

| Item | Value |
| --- | --- |
| libvirt domain | `win11-stock` |
| Disk | `/var/lib/libvirt/images/win11-stock.raw` (raw, 120 GiB) |
| Host storage | `/dev/nvme0n1p2` ext4, mounted at `/` (not `tank`) |
| Resources | 6 vCPU, 12 GiB, `host-passthrough`, Hyper-V enlightenments |
| Devices | virtio-blk, virtio-net, vTPM 2.0, virtio-gpu |
| Firmware | UEFI (OVMF), **Secure Boot off** — see the 2023 CA note |
| Local account | `Windows-PC` (password kept out of this repo) |
| Source media | official Windows 11 ISO, build 26300 |

The Windows image came from the **stock** ISO, not from
`windows/out/Win11-lean-*.iso`. The slim image's baked autounattend fails
OOBE on 26300 (`CUnattendManager::Initialize 0x80070490`,
`BCD ... c000000f`), even with Secure Boot off. Install Windows first, then
apply the debloat as a normal first-logon script (see *Debloat* below).

## Install notes

- At the disk step, load `viostor\w11\amd64` from the virtio-win CD.
- After the first reboot, **eject the install ISO**; the no-prompt EFI boot
  image otherwise starts Setup again in a loop:
  `sudo virsh change-media win11-stock sda --eject --live`.
- Install `virtio-win-guest-tools.exe` from the virtio-win CD for the NIC,
  graphics and balloon drivers.
- Enable TRIM as Administrator:
  `fsutil behavior set DisableDeleteNotify 0`.
- Secure Boot is off because Windows 11 24H2+ boot managers are signed with
  the Microsoft UEFI CA 2023, which the OVMF vars template used here does not
  trust. TPM 2.0 remains enabled.

## Autostart

The domain is created with autostart disabled.  To start it with the host:

```bash
sudo virsh autostart win11-stock
sudo virsh dominfo win11-stock | grep Autostart     # Autostart: enable
```

`dominfo` is the authoritative check.  On NixOS libvirt keeps its config
under `/var/lib/libvirt`, not `/etc`; locate the autostart link with:

```bash
sudo find /var/lib/libvirt /etc/libvirt -maxdepth 5 \
  \( -name autostart -o -name 'win11-stock.xml' \) -print
sudo virsh net-info default | grep Autostart        # network must autostart too
```

Autostart is applied when libvirtd starts, so it takes effect on the next
host boot and does not need a reboot to confirm the setting.

`sudo virsh autostart --disable win11-stock` reverts it.  The default libvirt
network is started by the NixOS module at boot, so the guest gets its lease
without manual steps.

## Enabling RDP (no typing in the console)

The scripts are kept in [`../scripts/windows/`](../scripts/windows/); build
the CD with:

```bash
cd scripts/windows
./make-helper-iso.sh /tmp/windows-helper.iso
```

The SPICE console plus a German keymap makes typing long commands painful.
Put the commands on a helper CD and double-click a batch file.

### 1. Build the helper CD on the host

```bash
rm -rf /tmp/win-helper && mkdir -p /tmp/win-helper

cat > /tmp/win-helper/enable-rdp.ps1 <<'EOF'
$ErrorActionPreference = 'Continue'
Write-Host '== Computer =='; hostname
Write-Host '== Local users =='; Get-LocalUser | Select-Object Name,Enabled | Format-Table -AutoSize

Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0

New-NetFirewallRule -DisplayName 'RDP 3389' -Direction Inbound -Protocol TCP `
  -LocalPort 3389 -Action Allow -Profile Any -ErrorAction SilentlyContinue

Get-NetConnectionProfile | ForEach-Object {
  Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
}

$v = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Host ("Edition: " + $v.ProductName + " / " + $v.EditionID)

Get-NetFirewallRule -DisplayName 'RDP 3389' | Format-Table DisplayName,Enabled,Direction,Action
netstat -an | Select-String ':3389'
Write-Host 'Done.'
EOF

cat > /tmp/win-helper/enable-rdp.bat <<'EOF'
@echo off
net session >nul 2>&1
if not "%errorlevel%"=="0" (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0enable-rdp.ps1"
echo.
pause
EOF

# cmd.exe needs CRLF in the batch file
sed -i 's/$/\r/' /tmp/win-helper/enable-rdp.bat

xorriso -as mkisofs -o /tmp/win-helper.iso -J -R /tmp/win-helper
```

### 2. Insert it in the guest

The virtio-win CD is no longer needed once the guest tools are installed, so
replace it. Use a **fresh ISO name** each time: an ISO that is inserted in the
running domain is open, and `xorriso` cannot overwrite it.

```bash
sudo virsh change-media win11-stock sdb --eject --live
sudo virsh change-media win11-stock sdb /tmp/win-helper.iso --insert --live
sudo virsh domblklist win11-stock
```

In Windows: File Explorer → the CD drive → **F5** → double-click
`enable-rdp.bat` → **Ja** on UAC.

The batch re-launches itself elevated and calls PowerShell with
`-ExecutionPolicy Bypass`, so a machine policy that blocks scripts does not
matter. The script enables RDP, creates a TCP 3389 firewall rule, sets the
network profile to Private, and prints the edition, users and listener.

Two known quirks:

- `Get-NetFirewallRule -DisplayGroup 'Remote Desktop'` returns nothing on a
  German system (the group is `Remotedesktop`). Use the explicit port rule,
  which is language-independent.
- `virsh attach-disk ... --type cdrom` can fail with
  *“No more available PCI slots”*. Replacing the existing SATA CD with
  `change-media` avoids it.

## Connecting from macOS

The guest is behind libvirt NAT (`192.168.122.0/24`), so the Mac cannot reach
it directly. `192.168.178.5:3389` is the host's xrdp, not Windows.

```bash
# on the NixOS host, note the guest address
sudo virsh domifaddr win11-stock --source lease

# on the Mac, keep this open
ssh -N -L 13389:192.168.122.238:3389 nixos@192.168.178.5
```

Then in **Windows App** (formerly Microsoft Remote Desktop):

- PC name: `localhost:13389`
- User: `.\Windows-PC`
- Password: from the password manager

Check the tunnel from the Mac with `nc -vz localhost 13389`; it must report
success before the client connects.

### Pin the guest address

DHCP can move the address after a reboot. Reserve it (get the MAC from
`virsh dumpxml win11-stock`):

```bash
sudo virsh net-update default add ip-dhcp-host \
  '<host mac="52:54:00:b6:38:f5" name="win11-stock" ip="192.168.122.50"/>' \
  --live --config
```

After a guest reboot the tunnel becomes
`ssh -N -L 13389:192.168.122.50:3389 nixos@192.168.178.5`.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Setup loops after install | Install ISO still attached; eject `sda` |
| Disk list empty in Setup | Load `viostor\w11\amd64` from the virtio-win CD |
| `Get-NetFirewallRule -DisplayGroup` finds nothing | German localization; use the port rule |
| Script blocked by execution policy | Run `enable-rdp.bat`, not the `.ps1` |
| `xorriso ... Permission denied` | ISO still inserted; eject `sdb` first, use a new filename |
| RDP `Access denied` | Wrong user form; use `COMPUTER\user` from `whoami` |
| RDP not offered | Windows edition is Home; hosting needs Pro |

## Debloat

`windows/scripts/SetupComplete.ps1` is a normal PowerShell script. Copy it
into the guest (helper CD or the Samba share) and run as Administrator:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\SetupComplete.ps1 -ProfileName lean
```

It removes consumer AppX packages, disables telemetry services and scheduled
tasks, and leaves Store, Defender and Windows Update working.

## See also

- [`../install/README.md`](../install/README.md) — VM creation, Secure Boot
  limitation, boot order
- [`../SECURITY.md`](../SECURITY.md) — host exposures incl. the guest account
- [`../scripts/zfs-audit.sh`](../scripts/zfs-audit.sh) — host state