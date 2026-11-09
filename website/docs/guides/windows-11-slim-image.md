---
title: Build an ultra-slim Windows 11 image
sidebar_label: Ultra-slim Windows 11
sidebar_position: 7
description: Build a lean, unattended Windows 11 ISO on NixOS with wimlib, xorriso and a first-boot debloat script.
---

# Build an ultra-slim Windows 11 image

You can build a custom Windows 11 ISO from NixOS without DISM and without a
Windows build host. The toolkit in [`windows/`](https://github.com/403access/nixos/tree/main/windows)
extracts the ISO, applies one edition, injects an unattended setup, removes
consumer apps and telemetry at first boot, recompresses the WIM and packs a
bootable ISO.

:::danger
This is an unsupported way to install Windows. A heavily stripped image can
break Windows Update, drivers, .NET, the Store, recovery or future feature
updates. Always test the ISO in a virtual machine first, keep a known-good
Windows installation and recovery media, and do not use an empty password on a
machine that can reach a network.
:::

## What "slim" means here

There are three independent layers. Keeping them separate makes the result much
more reliable than deleting folders from a mounted WIM:

1. **Install media** — extract the ISO, select one edition, clean caches,
   recompress `install.wim` and rebuild the boot records.
2. **Unattended setup** — a local administrator, no Microsoft account, and
   optional checks for TPM, Secure Boot, RAM, CPU and storage.
3. **First-boot debloat** — remove provisioned AppX packages and apply policy
   tweaks through supported Windows cmdlets after Setup has run.

NixOS is excellent at layer 1 and can prepare layer 2 and 3. NixOS cannot run
DISM offline, so true component servicing (Defender, WinSxS, optional features,
language packages) still needs a Windows VM with DISM, NTLite or MSMG Toolkit.
The guide covers that advanced path separately.

## What you get

| Profile | Removes | Keeps | Intended use |
| --- | --- | --- | --- |
| `safe` | Setup caches, logs, temporary files; recompressed WIM | Everything else | Daily driver, maximum compatibility |
| `lean` | Consumer AppX apps, telemetry services/tasks, consumer suggestions, Copilot policies | Store, Defender, Windows Update, OneDrive | Recommended |
| `micro` | `lean` + Store, Xbox, OneDrive, search index, SysMain, optionally WinRE | Defender and Windows Update | Experimental; requires `--experimental` |

The installed footprint depends on the Windows build, drivers and the profile.
A `lean` installation commonly lands around 8–12 GB on disk and a `micro`
installation lower, but do not treat any number as a guarantee. Idle RAM in the
1–2 GB range is possible with aggressive removal; it is not a supported target.

`lean` and `micro` remove AppX packages at first boot, so the `install.wim` still
contains them. The installed system gets smaller, not necessarily the ISO. For a
smaller ISO, add `--solid` and `--remove-winre`, or remove components offline
with DISM/NTLite as described below.

## Requirements

- A legally obtained Windows 11 x64 ISO (for example from Microsoft's download
  page). The toolkit does not download Windows and does not activate it.
- NixOS or another Linux system with `wimlib`, `p7zip`, `xorriso` and `python3`.
  The included `windows/shell.nix` provides all of them.
- About 20 GB free disk space. Solid compression temporarily needs more.
- A virtual machine for testing. On NixOS, QEMU/KVM with `virt-manager` is a good
  choice; Windows Setup needs no VirtIO drivers if you use IDE/SATA for the test
  disk.

## Quick start

From the repository root:

```bash
cd windows
nix-shell
./build-win11.sh --iso ~/Downloads/Win11_24H2_German_x64.iso --profile lean --locale de-DE
```

The script prints the generated local password. Store it before you close the
terminal, or pass your own password with `--password`.

A conservative image:

```bash
./build-win11.sh --iso ~/Downloads/Win11.iso --profile safe
```

An experimental micro image:

```bash
./build-win11.sh \
  --iso ~/Downloads/Win11.iso \
  --profile micro \
  --experimental \
  --solid \
  --remove-winre \
  --locale de-DE
```

The result is written to `windows/out/` with a `.sha256` file next to it.

## How the build works

```text
Windows ISO
    │
    ├─ 7z extract ──────────────────────────────► ISO tree
    │                                              │
    │                                              ├─ sources/install.wim (or .esd)
    │                                              │        │
    │                                              │        ├─ wimlib apply
    │                                              │        ├─ clean caches / optional WinRE
    │                                              │        ├─ inject autounattend.xml
    │                                              │        ├─ inject sources/$OEM$/$$/Setup/Scripts
    │                                              │        ├─ wimlib capture
    │                                              │        └─ optional solid compression
    │                                              │
    │                                              └─ xorriso ──► bootable ISO
    │
    └─ autounattend.xml + SetupComplete.ps1
```

The script intentionally uses `wimlib-imagex apply` and `capture` instead of a
read-write mount. That works on NixOS and macOS, avoids FUSE, and makes failures
easier to inspect.

:::note
wimlib is not a supported Windows servicing tool. It preserves file content and
WIM metadata, but Windows ACLs and security descriptors can differ from an image
serviced with DISM. Validate permissions and Windows Update behaviour in a VM
before deployment.
:::

If you want to poke at an image interactively on Linux:

```bash
sudo wimmountrw install.wim 6 /mnt/win11
# ... edit files under /mnt/win11 ...
sudo wimunmount /mnt/win11 --commit
```

Do not use `rm -rf` on `Program Files\WindowsApps` inside that mount. The AppX
provisioning database and the package files must stay in sync. Remove packages
through `Remove-AppxProvisionedPackage`, as the first-boot script does.

## Step 1: Get and verify the ISO

Download Windows 11 from Microsoft or another trusted source. Microsoft's Media
Creation Tool is Windows-only, so on NixOS use the direct ISO download or a
trusted mirror. Verify the hash before you modify anything:

```bash
sha256sum ~/Downloads/Win11.iso
# compare with the value published by the source
```

If your download is an ESD file or the ISO contains `sources/install.esd`, the
script converts it to `install.wim` with wimlib. Split `install*.swm` images are
not supported automatically; merge them with `wimlib-imagex join` first.

## Step 2: Enter the build shell

```bash
cd windows
nix-shell
```

The shell provides `wimlib-imagex`, `7z`, `xorriso`, `python3`, `hivex` and
`chntpw`. If you prefer a one-off shell:

```bash
nix-shell -p wimlib p7zip libisoburn python3
```

## Step 3: Choose the edition

The script auto-detects `Windows 11 Pro` and prints all images:

```text
Index:                  6
Name:                   Windows 11 Pro
```

Indexes differ between releases and languages. If auto-detection fails, list the
images and pass the index explicitly:

```bash
wimlib-imagex info /path/to/install.wim
./build-win11.sh --iso Win11.iso --profile lean --index 6
```

After the build the new WIM contains exactly one image, so `autounattend.xml`
refers to index `1`. The script handles that automatically.

## Step 4: Understand the unattended setup

Use a locale that is present in the source ISO. Setting `--locale de-DE` on an
English-only ISO may fall back to English or fail during Setup; download the
matching language image first.

The generated `autounattend.xml` does four things:

- sets the setup language and locale;
- selects the image index;
- creates a local administrator and hides the Microsoft-account screens;
- optionally bypasses TPM 2.0, Secure Boot, RAM, CPU and storage checks.

The hardware checks are bypassed with the well-known `LabConfig` registry
values:

```xml
<RunSynchronousCommand wcm:action="add">
  <Order>1</Order>
  <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
</RunSynchronousCommand>
```

Add `BypassSecureBootCheck`, `BypassRAMCheck`, `BypassCPUCheck` and
`BypassStorageCheck` the same way. Microsoft changes these checks between
releases, so test the exact build you deploy.

The generated file creates a local account with a random password by default.
That is deliberate: an empty administrator password plus auto-logon is a lab
convenience, not a security posture. Use `--password` to choose your own, and
`--autologon` only in a disposable VM.

Disk selection is left interactive. The script never guesses which disk to
erase. If you want a fully unattended disk layout, add `InstallTo` with the
correct `DiskID` and `PartitionID` to your own `autounattend.xml` and pass it
with `--unattend`. The build recaptures the selected edition as a single-image
WIM, so a custom answer file must reference `/IMAGE/INDEX` `1`.

:::warning
The hardware bypass is not a licence to run Windows 11 on hardware that Microsoft
does not support. Driver, firmware and update problems are your responsibility.
:::

## Step 5: First-boot debloat

For `lean` and `micro`, the build injects:

```text
sources/$OEM$/$$/Setup/Scripts/SetupComplete.cmd
sources/$OEM$/$$/Setup/Scripts/SetupComplete.ps1
```

Windows copies these to `C:\Windows\Setup\Scripts` and runs `SetupComplete.cmd`
once after Setup. The PowerShell script:

- removes provisioned AppX packages with `Remove-AppxProvisionedPackage`;
- removes installed packages with `Remove-AppxPackage -AllUsers`;
- disables telemetry services and scheduled tasks;
- applies policy values for telemetry, consumer features, Cortana, Copilot,
  Recall, activity history and delivery optimisation.

The AppX list lives in `windows/scripts/SetupComplete.ps1`. Edit the
`$leanPatterns` or `$microPatterns` arrays if you want to keep or remove an app.
Package names change between Windows releases; the script logs each failure and
continues instead of aborting the setup.

`lean` keeps the Store, Defender, Windows Update and OneDrive. `micro` removes
the Store, Xbox, OneDrive, search indexing and SysMain. Removing the Store also
removes the normal way to install and update packaged apps; keep `winget` and a
browser installer handy if you choose `micro`.

## Step 6: Build and test

Build the ISO, then test it before writing it to a USB stick:

```bash
qemu-system-x86_64 \
  -enable-kvm -m 4096 -smp 4 -cpu host \
  -drive file=win11-test.qcow2,if=ide,format=qcow2 \
  -cdrom windows/out/Win11-lean-*.iso \
  -boot d
```

Create the disk first if needed:

```bash
qemu-img create -f qcow2 win11-test.qcow2 40G
```

On a machine without KVM, remove `-enable-kvm -cpu host`; the test will be slow
but still useful.

Write the ISO to a USB stick only after the VM boots and installs:

```bash
lsblk
sudo dd if=windows/out/Win11-lean-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Replace `/dev/sdX` with the **whole disk**, not a partition. This destroys the
target device. Ventoy and similar tools are less error-prone for removable
media.

The ISO uses ISO level 3, so `install.wim` may be larger than 4 GiB. That is
fine for `dd` and Ventoy, but not for a manually prepared FAT32 stick. If you
need FAT32, skip `--solid` and split the WIM with `wimlib-imagex split`, keeping
the `.swm` files in `sources/`. Solid-compressed WIMs cannot be split.

## Step 7: Validate the installed system

Before you deploy the image, check at least:

- UEFI boot works (and BIOS/CSM if you still need it).
- The local account logs in; no Microsoft account is requested.
- Network, audio, GPU, sleep and USB work.
- Windows Update can download and install an update (for `safe` and `lean`).
- Store and `winget` work (for `lean`; `micro` intentionally removes the Store).
- Defender is present and updating (unless you deliberately removed it).
- A browser, 7-Zip, .NET and your actual line-of-business apps start.
- `sfc /scannow` and, if servicing is intact,
  `DISM /Online /Cleanup-Image /RestoreHealth` finish successfully.
- Event Viewer has no repeating critical errors after the first boot.

If Windows Update fails after aggressive removal, the usual cause is a removed
servicing component or a missing language/feature package. Restore the original
image rather than trying to patch the damage.

## What is removed, what remains

A `lean` or `micro` image usually keeps:

- the NT kernel, HAL, Win32 subsystem, WinUI and the classic desktop;
- Explorer, Task Manager, Control Panel, CMD and PowerShell;
- network, storage, GPU and input drivers that were in the source image;
- Win32 applications such as Firefox, 7-Zip, Notepad++ or portable tools;
- Defender and Windows Update (unless you go beyond `micro` with DISM/NTLite).

It usually loses:

- consumer AppX packages: Xbox, Zune, Your Phone, News, Weather, Solitaire,
  Clipchamp, Teams consumer, Office Hub, Mail/Calendar and similar;
- telemetry services and scheduled tasks;
- consumer suggestions, Cortana web search, Copilot/Recall policies;
- the Store, search index and OneDrive in `micro`;
- WinRE if you pass `--remove-winre`.

What is **not** removed by this toolkit:

- Windows Defender (disabling it is not the same as removing it);
- Windows Update or the CBS/DISM servicing stack;
- WinSxS (never delete it manually);
- Edge/WebView2 (many applications depend on WebView2);
- language packs and optional features (use DISM in a Windows VM).

Those changes are where "ultra-slim" becomes unsupported. If you remove the
servicing stack, the image is effectively frozen at the build you baked in, and
cumulative updates will fail. If you remove Defender, you are responsible for
endpoint security. If you remove WinSxS or the component store, `sfc` and
`DISM /RestoreHealth` can no longer repair the system.

## Advanced: true offline component removal

If you need to remove Defender, Edge, optional features, language packs or
components before Setup runs, use a Windows environment for servicing:

1. Create a Windows 11 VM with QEMU/KVM, VirtualBox or VMware.
2. Attach the extracted ISO tree or the `install.wim`.
3. Use DISM offline:

   ```powershell
   dism /Mount-Image /ImageFile:C:\Win11\sources\install.wim /Index:6 /MountDir:C:\Mount
   dism /Image:C:\Mount /Get-ProvisionedAppxPackages
   dism /Image:C:\Mount /Remove-ProvisionedAppxPackage /PackageName:<name>
   dism /Unmount-Image /MountDir:C:\Mount /Commit
   ```

4. Or use NTLite (GUI) / MSMG Toolkit (batch) inside that VM.
5. Copy the modified `install.wim` back into the NixOS build tree, or rebuild
   the ISO with the same `xorriso` command.

DISM is the supported servicing engine. wimlib can read and write the WIM, but
it does not replace DISM's component store logic. That is why the default
toolkit removes apps at first boot instead of pretending to service components
offline.

## GUI and batch alternatives

If you prefer to do the image surgery on a Windows host or in a Windows VM, the
two established tools are NTLite and MSMG Toolkit. They can remove components
that wimlib cannot service safely. Both still require a legally obtained ISO and
a test machine.

### NTLite

NTLite is the GUI standard for offline Windows modification. The free edition
covers basic trimming; the paid editions unlock deeper component removal.

1. Extract the ISO to a short path such as `C:\Win11ISO`.
2. Start NTLite, add the extracted folder and select the edition.
3. **Components** — remove consumer AppX packages (Xbox, Zune, Your Phone, Get
   Started, Solitaire, Weather, News), and optional features such as Cortana,
   Internet Explorer/legacy Edge, speech and telemetry. Do not remove WinSxS,
   the network stack, storage controllers or the graphics stack.
4. **Updates / Drivers** — integrate the latest cumulative update and the
   NVMe/chipset/storage drivers you need.
5. **Unattended / Settings** — disable telemetry and Cortana, skip the OneDrive
   setup pressure, and configure a local administrator.
6. **Apply** — use *Save and Trim* or *Create ISO*.
7. Test the result in a VM before touching hardware.

NTLite is proprietary. Keep the preset file and the source ISO so the build is
reproducible.

### MSMG Toolkit

MSMG Toolkit is a free, batch-based toolkit. It is less polished than NTLite but
scripts well and gives you direct control.

1. Extract the toolkit and place the Windows ISO in its `Source` directory.
2. Run `Start.cmd` as administrator.
3. **Source (1)** — read the source image.
4. **Integrate (2)** — add drivers, language packs or updates.
5. **Remove (3)** — remove Metro/AppX apps and Windows components. Stay away
   from WinSxS, servicing, networking and storage.
6. **Customize (4)** — enable or disable optional features.
7. **Apply (5)** — commit the changes to `install.wim`.
8. **Target (6)** — create the bootable ISO.

### Tiny11builder and post-install scripts

`tiny11builder` is a PowerShell script that removes a curated AppX/component
set. It is convenient, but it is still an unsupported modification; review the
script before running it and test the exact Windows build.

For tuning after installation, look at [Sophia Script for
Windows](https://github.com/farag2/Sophia-Script-for-Windows) or the [Chris Titus
Tech Windows Utility](https://github.com/ChrisTitusTech/winutil). They can
remove leftover AppX packages, disable SysMain or telemetry tasks and adjust
services. Do not run them blindly on a production machine. If you need a
reusable image, make the changes in audit mode and generalize the installation
with `sysprep`; otherwise treat the result as a one-off installation.

| Approach | Runs on | Strength | Trade-off |
| --- | --- | --- | --- |
| This toolkit | NixOS/Linux | Reproducible ISO assembly, unattended setup, first-boot debloat | No native DISM component servicing |
| NTLite | Windows | Precise GUI component removal | Proprietary, easy to over-remove |
| MSMG Toolkit | Windows | Free, batch-oriented | Dated UI, manual steps |
| tiny11builder | Windows | Quick scripted trim | Unsupported, build-specific |
| DISM in a VM | Windows | Supported servicing engine | Slow, needs a Windows VM |

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Setup asks for a product key | No key and no edition selected | Use `--index`, or add `--product-key` |
| Setup stops at disk selection | `ImageInstall` has no `InstallTo` | Choose the disk interactively, or add `InstallTo` to your own answer file |
| Setup asks for a Microsoft account | Unattend not found or ignored | Put `autounattend.xml` in the ISO root; do not rename it |
| `0x80070570` during install | Corrupt extraction or ISO | Re-download, verify SHA-256, rebuild without `--solid` |
| Boot loop after first boot | Bad unattend or removed system component | Rebuild with `safe`, then add changes one at a time |
| Store missing | `micro` profile | Use `lean`, or reinstall the Store |
| Windows Update fails | Servicing stack or component store removed | Restore the original image; do not delete WinSxS |
| AppX removal logs failures | Package name changed in this Windows build | Adjust the pattern in `SetupComplete.ps1`; failures are non-fatal |
| `wimlib-imagex` permission errors | ACLs on a non-root apply | Run the build as root or accept that ACLs are not preserved |
| USB does not boot | Written to a partition, or FAT32 size limit | Write the ISO to the whole disk; use Ventoy or split the WIM |

## Script reference

| Option | Purpose |
| --- | --- |
| `--iso PATH` | Source Windows 11 ISO. Required. |
| `--profile safe\|lean\|micro` | Debloat level. Default `lean`. |
| `--out PATH` | Output ISO path. |
| `--index N` | Source WIM index. Default: auto-detect Windows 11 Pro. |
| `--locale de-DE` | Setup language and locale. |
| `--input-locale VALUE` | Input locale if your locale is not in the built-in map, e.g. `0407:00000407`. |
| `--user NAME` | Local administrator name. Default `Admin`. |
| `--password VALUE` | Local password. A random password is generated by default. |
| `--allow-empty-password` | Explicitly allow a blank password. Not recommended. |
| `--autologon` | One auto-logon. Lab use only. |
| `--product-key KEY` | Optional product key. |
| `--computer-name NAME` | Optional computer name. |
| `--unattend PATH` | Use your own `autounattend.xml`. |
| `--no-unattend` | Skip `autounattend.xml` entirely. |
| `--no-postinstall` | Skip the first-boot debloat script. |
| `--remove-winre` | Remove WinRE from the image. |
| `--solid` | Solid-compress the WIM. Smaller, slower. |
| `--experimental` | Required for `micro`. |
| `--workdir PATH` | Working directory. Default `windows/work`. |
| `--keep-work` | Keep the extracted tree for inspection. |
| `--force` | Overwrite an existing output ISO. |

## Legal and operational notes

- Windows is licensed software. Do not redistribute a modified ISO.
- A modified image is not supported by Microsoft. Keep the original ISO and a
  recovery plan.
- Do not bake passwords, product keys or tokens into a public repository. The
  generated `autounattend.xml` contains the local password you choose.
- Test with the exact Windows build you plan to deploy. AppX names, setup
  behaviour and hardware checks change between releases.
- If the machine is reachable from a network, use a real password, full-disk
  encryption where appropriate, and a supported security stack.

## Next steps

- [Desktop profiles](./desktop.md) — choose the NixOS desktop for the build host.
- [Configuration](./configuration.md) — the rest of this repository's NixOS
  options.
- [`windows/README.md`](https://github.com/403access/nixos/blob/main/windows/README.md)
  — the short command reference.
