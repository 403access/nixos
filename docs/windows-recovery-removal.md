# Windows recovery removal and redeploy strategy

Guest: `win11-stock`, Windows 11 build 26300. Applied **2026-11-22**.

This VM is used for music production (FL Studio), not as a system to repair.
Backups are expected to live outside the guest; recovery relies on redeploying a
clean VM rather than WinRE/Reset.

## What was removed

- **Windows RE payload:** `reagentc /disable`; `Winre.wim` deleted (763 MB).
- **Recovery partition:** GPT partition 4 (911 MB) deleted; `C:` extended from
  118.9 GB to **119.79 GB** and NTFS grown into it.
- **BCD recovery:** `recoveryenabled No`, `bootstatuspolicy IgnoreAllFailures`;
  `displaymessageoverride Recovery` removed.
- **System Restore / shadow copies:** `vssadmin delete shadows /for=C: /all`
  and `Disable-ComputerRestore` (SDRSVC was already disabled).
- **WinRE tasks:** `\Microsoft\Windows\RecoveryEnvironment\VerifyWinRE` removed;
  `SetupRecoveryDataTask` removed/disabled.

## Final state

```text
Windows RE status: Disabled
Partitions:        1 System (200 MB), 2 Reserved (16 MB), 3 C: (119.79 GB)
C: free:           87.76 GB
Winre.wim:         absent
VSS shadows:       none
C: dirty flag:     clean (chkdsk /f completed)
```

A tiny `C:\Windows\System32\Recovery\ReAgent.xml` can be recreated by Windows;
it is inert without `Winre.wim`. WinRE setup/repair tasks are disabled.

`ntfsresize` marked `C:` dirty after growing it; `chkdsk /f` ran on the next
boot and cleared the flag (`fsutil dirty query C:` now reports not dirty).

## Trade-offs

- **No Startup Repair, Reset this PC, System Restore, or WinRE Command Prompt.**
- **No recovery partition or recovery boot menu.**
- Windows feature updates may recreate WinRE/recovery data. After a feature
  update, re-check:
  ```powershell
  reagentc /info
  Get-Partition
  ```
  and repeat `reagentc /disable` if it says `Enabled`.
- Monthly cumulative updates normally do not recreate the partition; verify
  after large upgrades.

## Rollback

The GPT table was backed up before the edit on the host:

```text
/root/win11-stock-gpt-20261122-234141.bin
```

To restore the table (VM shut down, disk attached with `qemu-nbd`):

```bash
sudo sgdisk --load-backup=/root/win11-stock-gpt-20261122-234141.bin /dev/nbd0
sudo partprobe /dev/nbd0
```

This restores the 911 MB recovery partition entry, but **does not restore
`Winre.wim`** — the payload was deleted. There is therefore no useful WinRE to
return to unless you rebuild it from Windows installation media. The extended
NTFS filesystem remains valid; shrinking it back requires `ntfsresize`.

## Redeploy a clean VM

The supported path is a fresh unattended Windows install plus the repo's
post-install trims:

1. Build or reuse a Windows ISO with Image Studio:
   ```bash
   cd image-studio
   node bin/image-studio.js web
   # Windows tab -> source ISO -> lean/micro -> Build -> Export bundle
   ```
   The Windows builder includes `autounattend.xml` unless `--no-unattend` was
   used.
2. Create a new VM from that ISO on the host:
   ```bash
   sudo ./install/windows-vm-create.sh \
     --name win11-redeploy \
     --iso /path/to/Win11-lean.iso \
     --memory 4096 --vcpus 2 --disk-size 120G --raw
   ```
   Add `--virtio-iso` if the virtio-win ISO is not auto-detected. The helper
   uses UEFI/vTPM and starts the installer.
3. After first logon, apply the recorded profile/trims with Image Studio:
   `win_recipe`, `win_autologon`, `win_rdp_limits`, `win_service_set`, or the
   exported bundle's post-install recipe plan.
4. Copy data back from the host share. The current `win11-stock` XML has **no
   virtiofs/9p/Samba share** configured yet; add one before relying on it.

## Data and apps

- Keep project files, samples, presets and installers on the host/shared folder;
  do not rely on the guest disk as the only copy.
- Record plugin/app installers and licence steps in the redeploy notes.
- The Windows ISO, profile bundle and `C:\ProgramData\WindowsSlim` state are the
  reusable pieces.

## Related

- [`windows-vm.md`](windows-vm.md) — guest operations and RDP/SSH
- [`windows-ai-removal.md`](windows-ai-removal.md) — offline image edits
- [`image-studio.md`](image-studio.md) — build/export/import workflow
- [`../image-studio/README.md`](../image-studio/README.md) — MCP/web tooling