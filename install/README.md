# Installation layouts

`install/install.sh` prepares a machine for one of three layouts:

| Mode | What you get |
| --- | --- |
| `nixos` | NixOS only. Windows is not installed and no VM is configured. |
| `vm` | NixOS only, plus libvirt/QEMU, a virtual TPM and a `windows-vm-create` helper. Windows 11 runs in a VM. |
| `dual` | NixOS and Windows 11 on the same disk, with a systemd-boot menu. |

The script is interactive, defaults to a **dry run**, and only writes when you
pass `--apply`. It is intended to be run from the NixOS installer ISO as root,
from a checkout of this repository.

> **Back up first.** The `nixos` and `vm` modes wipe the selected disk. The
> `dual` mode with `--dual-order windows-first` preserves existing Windows
> partitions; `--dual-order nixos-first` wipes the disk and creates an empty
> Windows partition. Partitioning mistakes are permanent either way.

## Requirements

- x86_64 UEFI machine. Legacy BIOS and Secure Boot are not handled by the
  script.
- A NixOS installer ISO with network access and ZFS support. If `modprobe zfs`
  fails, use an ISO built with `boot.supportedFilesystems = [ "zfs" ]`; the
  installer stops before touching the disk when ZFS is unavailable.
- A copy of this repository in the live environment:

  ```bash
  git clone https://github.com/403access/nixos
  cd nixos
  ```

- For `dual` with existing Windows: free space on the Windows disk. Shrink the
  Windows partition from Windows Disk Management first. The script does not
  resize NTFS.
- For `vm`: a Windows 11 ISO. The repository's
  [slim-image toolkit](../windows/README.md) can build one.

## The three modes

### 1. NixOS only

```bash
sudo ./install/install.sh --mode nixos --disk /dev/nvme0n1
sudo ./install/install.sh --mode nixos --disk /dev/nvme0n1 --apply
```

Fresh GPT layout:

| # | Size | Use |
| --- | --- | --- |
| 1 | 1 GiB | ESP, vfat, mounted at `/boot` |
| 2 | 100 GiB (default) | NixOS root, ext4 |
| 3 | remainder | ZFS pool `tank`, mounted at `/mnt/tank` |

`--root-size` and `--esp-size` change the defaults. The ZFS pool keeps the
existing `boot.zfs.extraPools = [ "tank" ]` and Samba `/mnt/tank` setup
working.

### 2. NixOS with a Windows 11 VM

```bash
sudo ./install/install.sh --mode vm --disk /dev/nvme0n1 \
  --windows-iso ~/Downloads/Win11.iso --apply
```

The disk layout is identical to NixOS only. The installer also:

- copies the ISO to `/var/lib/libvirt/images/Win11.iso` (when `--windows-iso`
  is used);
- writes `myInstall.mode = "vm"` to `installation-mode.nix`.

After the first boot:

```bash
sudo windows-vm-create --iso /var/lib/libvirt/images/Win11.iso
virt-manager
```

`windows-vm-create` creates a UEFI VM with a virtual TPM, 8 GiB RAM, 4 vCPUs
and an 80 GiB SATA disk. SATA avoids the VirtIO driver step in Windows Setup.
Pass `--virtio --virtio-iso /path/to/virtio-win.iso` for a VirtIO disk and
network; you then load the `viostor` driver during Setup. Add `--secure-boot`
if you are using a stock Windows 11 ISO that insists on Secure Boot; the
repository's slim image can bypass the hardware checks instead.

The NixOS module enables `libvirtd`, `swtpm`, SPICE USB redirection,
virt-manager and the default NAT network.

### 3. NixOS and Windows dual boot

Two orders are supported.

**Windows already installed** (recommended):

```bash
sudo ./install/install.sh --mode dual --disk /dev/nvme0n1 \
  --dual-order windows-first --apply
```

The script detects the Windows ESP and NTFS partition, leaves them untouched,
and creates NixOS root and ZFS partitions in the free space. If the Windows ESP
is at least 512 MiB, NixOS shares it. systemd-boot then detects Windows
automatically.

**NixOS first, Windows later:**

```bash
sudo ./install/install.sh --mode dual --disk /dev/nvme0n1 \
  --dual-order nixos-first --apply
```

Fresh GPT layout:

| # | Size | Use |
| --- | --- | --- |
| 1 | 1 GiB | Shared ESP |
| 2 | 16 MiB | Microsoft Reserved (MSR) |
| 3 | 200 GiB (default) | Windows, left unformatted |
| 4 | 100 GiB (default) | NixOS root, ext4 |
| 5 | remainder minus 1 GiB | ZFS pool `tank` |
| — | 1 GiB unallocated | Windows Recovery can use it |

Install Windows into partition 3 afterwards. Windows Setup adds its boot
manager to the shared ESP. Boot NixOS once more and run:

```bash
sudo nixos-rebuild boot
```

systemd-boot regenerates its menu and detects Windows.

## Windows ISO build toolchain

The installer also chooses how the Windows 11 slim-image toolkit is provided.
This is independent of the three layouts:

```bash
sudo ./install/install.sh --mode nixos --disk /dev/nvme0n1 \
  --windows-toolchain native --apply
```

| Value | What it installs |
| --- | --- |
| `native` | `wimlib`, 7-Zip, `xorriso`, `ntfs-3g`, `chntpw`, `hivex`, `python3` and the `windows-build` wrapper on the host. |
| `docker` | Enables the Docker service and adds your user to the `docker` group. |
| `both` | Native packages plus Docker. |
| `none` | Neither; use `nix-shell` in `windows/` or the Docker wrapper manually. |

If `--windows-toolchain` is omitted, the installer prompts with `native`
selected by default. The installer copies `windows/` to `/etc/nixos/windows`
(excluding `work/` and `out/`), so the native build works after reboot.

Native build:

```bash
windows-build --iso ~/Downloads/Win11.iso --profile lean
```

`windows-build` keeps the output in `~/.local/share/windows-image/out` and the
temporary work directory in `~/.cache/windows-image/work`, so it does not need
write access to `/etc/nixos`. It accepts every `build-win11.sh` option.

Docker build:

```bash
cd /etc/nixos/windows
./build-win11-docker.sh --iso ~/Downloads/Win11.iso --profile lean
```

The repository default is `myInstall.windows.toolchain = "native"`, so a plain
`nixos-rebuild switch` on an existing host installs the native toolchain too.
Set it to `"none"` if you only build Windows images in Docker or in `nix-shell`.

## Boot chain

The default is **one shared ESP plus systemd-boot**:

- Windows and NixOS both put their loaders on the same FAT32 ESP.
- systemd-boot finds `\EFI\Microsoft\Boot\bootmgfw.efi` automatically.
- No `boot.loader.systemd-boot.windows` entry is needed.

If the Windows ESP is smaller than 512 MiB, the script creates a separate 1 GiB
ESP for NixOS. systemd-boot cannot see Windows across ESPs, so the installer
enables the EDK2 UEFI Shell. Find the Windows handle once:

1. Reboot and select **EDK2 UEFI Shell**.
2. Run `map -c`.
3. Find the handle whose `\EFI` directory contains `Microsoft`, for example
   `HD0b1`.
4. Test it: `HD0b1:\EFI\Microsoft\Boot\Bootmgfw.efi`.
5. Set it in `/etc/nixos/installation-mode.nix`:

   ```nix
   myInstall.dualBoot.windowsEfiDeviceHandle = "HD0b1";
   ```

6. Run `sudo nixos-rebuild boot`.

Windows also remains selectable from the firmware boot menu.

### Why not GRUB?

GRUB with `os-prober` works, but it is heavier and NixOS defaults to
systemd-boot. The shared-ESP layout is simpler and needs no extra configuration.
Use GRUB only if you need BIOS boot or a boot setup the script does not cover.

## Windows settings for dual boot

- **Disable Fast Startup** in Windows. It leaves NTFS in a half-shutdown state
  and can corrupt the Windows partition when Linux mounts it.
- **Suspend BitLocker** before changing the boot order or ESP, and keep the
  recovery key. Booting Windows through a third-party loader can trigger a
  recovery prompt. The NixOS module sets `time.hardwareClockInLocalTime = true`
  so Windows and Linux agree on the clock.
- **Secure Boot**: NixOS uses unsigned systemd-boot. Either disable Secure Boot
  or set up [lanzaboote](https://github.com/nix-community/lanzaboote). Windows
  11 requires Secure Boot capability, but it can run with Secure Boot off after
  installation.
- Windows updates can reorder UEFI boot entries. If the machine boots straight
  into Windows, use the firmware boot menu or `efibootmgr` to put systemd-boot
  first again.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `--mode` | prompt | `nixos`, `vm`, `dual` |
| `--disk` | prompt | Target block device |
| `--apply` | off | Actually partition and install |
| `--yes` | off | Skip the typed confirmation |
| `--no-install` | off | Partition and copy files, skip `nixos-install` |
| `--hostname` | unset | Set `networking.hostName` |
| `--user` | `nixos` | User added to `libvirtd` in VM mode |
| `--esp-size` | `1G` | ESP size for fresh layouts |
| `--root-size` | `100G` | NixOS root size |
| `--windows-size` | `200G` | Windows partition size for a fresh dual layout |
| `--dual-order` | auto | `windows-first` or `nixos-first` |
| `--windows-iso` | unset | ISO copied to `/var/lib/libvirt/images/Win11.iso` |
| `--windows-toolchain` | prompt (`native`) | `native`, `docker`, `both` or `none` |

## What the script changes

On the target system it:

- writes `myInstall.mode`, the Windows toolchain choice and the relevant
  options to `/etc/nixos/installation-mode.nix`;
- copies `configuration.nix`, `installation-mode.nix`, `nixos-control.nix`,
  `jotta-cli.nix`, `desktop/`, `server/`, `install/` and `windows/`;
- regenerates `hardware-configuration.nix` with `nixos-generate-config`;
- creates the `tank` ZFS pool and adds `/mnt/tank` if the generated hardware
  config does not already include it;
- runs `nixos-install --root /mnt --no-root-passwd`.

The repository's `configuration.nix` ships with the user `nixos` and password
`nixos`. Change it immediately after the first boot:

```bash
passwd nixos
```

## Limitations

- One disk only. Multi-disk ZFS pools, LUKS and LVM are not part of this
  installer.
- The `dual` mode does not shrink NTFS. Create free space first.
- The script does not install Windows for you. It prepares the partition, and
  you run Windows Setup from the ISO.
- Windows 11 activation and licensing are your responsibility.
- The generated layout is declarative only after installation; the installer
  itself is imperative and must be treated like any other destructive disk
  tool.
