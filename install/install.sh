#!/usr/bin/env bash
#
# Interactive NixOS installer for the three layouts supported by this repo:
#
#   1. NixOS only
#   2. NixOS only, with Windows 11 in a libvirt/QEMU VM
#   3. NixOS and Windows 11 dual boot
#
# Run this from the NixOS installer ISO, as root, from a checkout of this
# repository.  It partitions the selected disk, copies the configuration,
# generates hardware-configuration.nix, and runs nixos-install.
#
# Nothing is written unless --apply is passed.  Read install/README.md first.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

MODE=""
DISK=""
APPLY=0
YES=0
NO_INSTALL=0
HOSTNAME=""
USER_NAME="nixos"
ESP_SIZE="1G"
ROOT_SIZE="100G"
WINDOWS_SIZE="200G"
DUAL_ORDER=""
WINDOWS_ISO=""
WINDOWS_TOOLCHAIN=""
VM_ISO_TARGET="/var/lib/libvirt/images/Win11.iso"

HAS_WINDOWS=0
WIN_ESP=""
WIN_PART=""
NIXOS_ESP=""
NIXOS_ROOT=""
NIXOS_ZFS=""
WINDOWS_PART=""
SEPARATE_ESP=0

MIN_ZFS_BYTES=$((1024 * 1024 * 1024))
MSR_BYTES=$((16 * 1024 * 1024))
WINRE_BYTES=$((1024 * 1024 * 1024))

usage() {
  cat <<'EOF'
Usage: sudo ./install/install.sh --mode MODE --disk DEVICE [options]

Modes:
  nixos    NixOS only
  vm       NixOS only, with Windows 11 in a libvirt/QEMU VM
  dual     NixOS and Windows 11 dual boot

Required:
  --mode MODE             nixos | vm | dual
  --disk DEVICE           Target disk, for example /dev/nvme0n1

Options:
  --apply                 Actually partition and install (default: dry run)
  --yes                   Skip the confirmation prompt
  --no-install            Partition and copy files, but skip nixos-install
  --hostname NAME         Set networking.hostName in the installed system
  --user NAME             Desktop user to add to libvirtd (default: nixos)
  --esp-size SIZE         ESP size for a fresh layout (default: 1G)
  --root-size SIZE        NixOS root size (default: 100G)
  --windows-size SIZE     Windows partition size for a fresh dual layout
                          (default: 200G)
  --dual-order ORDER      windows-first | nixos-first
                          Default: windows-first when Windows is detected,
                          otherwise nixos-first.
  --windows-iso PATH      Copy this ISO to /var/lib/libvirt/images/Win11.iso
                          for the VM mode.
  --windows-toolchain MODE
                          native | docker | both | none
                          Default: prompt (native if you press Enter).
                          Native installs wimlib, 7-Zip, xorriso, ntfs-3g,
                          chntpw, hivex and python3 on this machine.
  -h, --help              Show this help

Examples:
  sudo ./install/install.sh --mode nixos --disk /dev/nvme0n1 --apply
  sudo ./install/install.sh --mode vm --disk /dev/nvme0n1 \
    --windows-iso ~/Downloads/Win11.iso --apply
  sudo ./install/install.sh --mode dual --disk /dev/nvme0n1 \
    --dual-order windows-first --apply

The script refuses to use a disk that is mounted or hosts the live system.
EOF
}

log() {
  printf '\033[1;34m==>\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode)
        MODE="${2:?--mode needs a value}"
        shift 2
        ;;
      --disk)
        DISK="${2:?--disk needs a value}"
        shift 2
        ;;
      --apply)
        APPLY=1
        shift
        ;;
      --yes)
        YES=1
        shift
        ;;
      --no-install)
        NO_INSTALL=1
        shift
        ;;
      --hostname)
        HOSTNAME="${2:?--hostname needs a value}"
        shift 2
        ;;
      --user)
        USER_NAME="${2:?--user needs a value}"
        shift 2
        ;;
      --esp-size)
        ESP_SIZE="${2:?--esp-size needs a value}"
        shift 2
        ;;
      --root-size)
        ROOT_SIZE="${2:?--root-size needs a value}"
        shift 2
        ;;
      --windows-size)
        WINDOWS_SIZE="${2:?--windows-size needs a value}"
        shift 2
        ;;
      --dual-order)
        DUAL_ORDER="${2:?--dual-order needs a value}"
        shift 2
        ;;
      --windows-iso)
        WINDOWS_ISO="${2:?--windows-iso needs a value}"
        shift 2
        ;;
      --windows-toolchain)
        WINDOWS_TOOLCHAIN="${2:?--windows-toolchain needs a value}"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "unknown option: $1"
        ;;
    esac
  done
}

size_to_bytes() {
  numfmt --from=iec "$1"
}

part_name() {
  local disk="$1"
  local number="$2"

  if [[ "$disk" =~ [0-9]$ ]]; then
    printf '%sp%s\n' "$disk" "$number"
  else
    printf '%s%s\n' "$disk" "$number"
  fi
}

next_part_number() {
  sgdisk --print "$DISK" \
    | awk '/^ +[0-9]+/ { if ($1 > max) max = $1 } END { print max + 1 }'
}

detect_windows() {
  HAS_WINDOWS=0
  WIN_ESP=""
  WIN_PART=""

  local name parttype fstype parttype_lc fstype_lc
  while read -r name parttype fstype; do
    [ -n "$name" ] || continue
    parttype_lc="${parttype,,}"
    fstype_lc="${fstype,,}"

    if [ -z "$WIN_ESP" ] \
      && { [ "$parttype_lc" = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ] \
        || [ "$parttype_lc" = "ef00" ]; }; then
      WIN_ESP="$name"
    fi

    if [ "$fstype_lc" = "ntfs" ] || [ "$fstype_lc" = "bitlocker" ]; then
      WIN_PART="$name"
    fi
  done < <(lsblk -lnpo NAME,PARTTYPE,FSTYPE "$DISK")

  if [ -n "$WIN_ESP" ] && [ -n "$WIN_PART" ]; then
    HAS_WINDOWS=1
  fi
}

free_space_bytes() {
  local sectors
  sectors="$(sgdisk --print "$DISK" \
    | awk -F': ' '/Total free space is/ { print $2 }' \
    | awk '{ print $1 }')"
  sectors="${sectors:-0}"
  printf '%s\n' "$((sectors * 512))"
}

check_environment() {
  [ "$(id -u)" -eq 0 ] || die "run this as root (sudo ./install/install.sh ...)"
  [ -d /sys/firmware/efi ] || die "this installer requires UEFI firmware"
  command -v sgdisk >/dev/null 2>&1 || die "sgdisk is missing"
  command -v mkfs.fat >/dev/null 2>&1 || die "mkfs.fat is missing"
  command -v mkfs.ext4 >/dev/null 2>&1 || die "mkfs.ext4 is missing"
  command -v zpool >/dev/null 2>&1 || die "zpool is missing"
  command -v modprobe >/dev/null 2>&1 || die "modprobe is missing"
  command -v partprobe >/dev/null 2>&1 || die "partprobe is missing"
  command -v udevadm >/dev/null 2>&1 || die "udevadm is missing"
  command -v blkid >/dev/null 2>&1 || die "blkid is missing"
  command -v wipefs >/dev/null 2>&1 || die "wipefs is missing"
  command -v mount >/dev/null 2>&1 || die "mount is missing"
  command -v lsblk >/dev/null 2>&1 || die "lsblk is missing"
  command -v findmnt >/dev/null 2>&1 || die "findmnt is missing"
  command -v numfmt >/dev/null 2>&1 || die "numfmt is missing"
  command -v tar >/dev/null 2>&1 || die "tar is missing"
  command -v nixos-generate-config >/dev/null 2>&1 || die "nixos-generate-config is missing"
  command -v nixos-install >/dev/null 2>&1 || die "run this from the NixOS installer ISO"
  modprobe zfs 2>/dev/null \
    || die "ZFS is not available in this installer; use a NixOS ISO with ZFS support"
}

select_mode() {
  [ -n "$MODE" ] && return

  printf 'Choose the installation layout:\n'
  printf '  1) NixOS only\n'
  printf '  2) NixOS + Windows 11 VM\n'
  printf '  3) NixOS + Windows 11 dual boot\n'
  read -r -p 'Mode [1-3]: ' choice

  case "$choice" in
    1) MODE="nixos" ;;
    2) MODE="vm" ;;
    3) MODE="dual" ;;
    *) die "invalid mode: $choice" ;;
  esac
}

select_windows_toolchain() {
  [ -n "$WINDOWS_TOOLCHAIN" ] && return

  printf '\n'
  printf 'Windows 11 ISO build toolchain:\n'
  printf '  1) Native packages on this machine (recommended)\n'
  printf '  2) Docker\n'
  printf '  3) Both\n'
  printf '  4) None\n'
  read -r -p 'Toolchain [1]: ' choice

  case "${choice:-1}" in
    1) WINDOWS_TOOLCHAIN="native" ;;
    2) WINDOWS_TOOLCHAIN="docker" ;;
    3) WINDOWS_TOOLCHAIN="both" ;;
    4) WINDOWS_TOOLCHAIN="none" ;;
    *) die "invalid toolchain: $choice" ;;
  esac
}

validate_windows_toolchain() {
  case "$WINDOWS_TOOLCHAIN" in
    native | docker | both | none) ;;
    *) die "invalid --windows-toolchain: $WINDOWS_TOOLCHAIN (use native, docker, both or none)" ;;
  esac
}

select_disk() {
  [ -n "$DISK" ] && return

  printf 'Available disks:\n'
  lsblk -dpno NAME,SIZE,MODEL | sed 's/^/  /'
  read -r -p 'Disk to use (for example /dev/nvme0n1): ' DISK
}

validate_mode() {
  case "$MODE" in
    nix | nixos) MODE="nixos" ;;
    vm | windows-vm) MODE="vm" ;;
    dual | dual-boot) MODE="dual" ;;
    *) die "invalid mode: $MODE (use nixos, vm or dual)" ;;
  esac
}

validate_disk() {
  [ -b "$DISK" ] || die "not a block device: $DISK"
  DISK="$(readlink -f "$DISK")"

  if lsblk -no MOUNTPOINT "$DISK" | grep -q .; then
    die "$DISK or one of its partitions is mounted; unmount it first"
  fi

  local live_source
  live_source="$(findmnt -n -o SOURCE / || true)"
  if [ -n "$live_source" ] && [[ "$live_source" == "$DISK"* ]]; then
    die "refusing to use the live system's disk ($live_source)"
  fi
}

validate_sizes() {
  local esp_bytes root_bytes windows_bytes disk_bytes required

  esp_bytes="$(size_to_bytes "$ESP_SIZE")"
  root_bytes="$(size_to_bytes "$ROOT_SIZE")"
  windows_bytes="$(size_to_bytes "$WINDOWS_SIZE")"
  disk_bytes="$(blockdev --getsize64 "$DISK")"

  if [ "$MODE" = "dual" ]; then
    required=$((esp_bytes + MSR_BYTES + windows_bytes + root_bytes + WINRE_BYTES + MIN_ZFS_BYTES))
  else
    required=$((esp_bytes + root_bytes + MIN_ZFS_BYTES))
  fi

  if [ "$required" -gt "$disk_bytes" ]; then
    die "layout needs $((required / 1024 / 1024 / 1024)) GiB but $DISK has $((disk_bytes / 1024 / 1024 / 1024)) GiB; reduce --root-size/--windows-size or use a larger disk"
  fi
}

plan_fresh_layout() {
  local include_windows="$1"

  NIXOS_ESP="$(part_name "$DISK" 1)"
  if [ "$include_windows" -eq 1 ]; then
    WINDOWS_PART="$(part_name "$DISK" 3)"
    NIXOS_ROOT="$(part_name "$DISK" 4)"
    NIXOS_ZFS="$(part_name "$DISK" 5)"
  else
    WINDOWS_PART=""
    NIXOS_ROOT="$(part_name "$DISK" 2)"
    NIXOS_ZFS="$(part_name "$DISK" 3)"
  fi

  log "Fresh GPT layout on $DISK"
  printf '  ESP:       %s (%s)\n' "$NIXOS_ESP" "$ESP_SIZE"
  if [ "$include_windows" -eq 1 ]; then
    printf '  MSR:       %s (16 MiB)\n' "$(part_name "$DISK" 2)"
    printf '  Windows:   %s (%s, left for Windows Setup)\n' "$WINDOWS_PART" "$WINDOWS_SIZE"
  fi
  printf '  NixOS:     %s (%s, ext4)\n' "$NIXOS_ROOT" "$ROOT_SIZE"
  printf '  ZFS tank:  %s (remainder)\n' "$NIXOS_ZFS"
  if [ "$include_windows" -eq 1 ]; then
    printf '  WinRE gap: 1 GiB unallocated at the end\n'
  fi
}

plan_existing_windows() {
  local esp_bytes free_bytes root_bytes

  esp_bytes="$(blockdev --getsize64 "$WIN_ESP")"
  free_bytes="$(free_space_bytes)"
  root_bytes="$(size_to_bytes "$ROOT_SIZE")"

  if [ "$esp_bytes" -lt $((512 * 1024 * 1024)) ]; then
    SEPARATE_ESP=1
    warn "the Windows ESP ($WIN_ESP) is smaller than 512 MiB"
    warn "creating a separate $ESP_SIZE ESP for NixOS; Windows will still be bootable from the firmware menu"
    if [ "$free_bytes" -lt $(( $(size_to_bytes "$ESP_SIZE") + root_bytes + MIN_ZFS_BYTES )) ]; then
      die "not enough free space for a separate ESP plus NixOS; shrink the Windows partition first"
    fi
  else
    SEPARATE_ESP=0
    if [ "$free_bytes" -lt $((root_bytes + MIN_ZFS_BYTES)) ]; then
      die "not enough free space for NixOS; shrink the Windows partition first (Windows Disk Management or ntfsresize)"
    fi
  fi

  log "Existing Windows installation on $DISK"
  printf '  Windows:   %s\n' "$WIN_PART"
  printf '  Windows ESP: %s (%s)\n' "$WIN_ESP" "$(numfmt --to=iec "$esp_bytes")"
  if [ "$SEPARATE_ESP" -eq 1 ]; then
    printf '  NixOS ESP: new %s partition\n' "$ESP_SIZE"
  else
    printf '  NixOS ESP: shares the Windows ESP\n'
  fi
  printf '  NixOS:     new %s ext4 partition\n' "$ROOT_SIZE"
  printf '  ZFS tank:  new partition from the remaining free space\n'
}

create_fresh_layout() {
  local include_windows="$1"

  log "Wiping and partitioning $DISK"
  sgdisk --zap-all "$DISK"
  sgdisk --clear "$DISK"

  sgdisk \
    --new=1:0:+"$ESP_SIZE" \
    --typecode=1:ef00 \
    --change-name=1:ESP \
    "$DISK"

  if [ "$include_windows" -eq 1 ]; then
    sgdisk \
      --new=2:0:+"$MSR_BYTES" \
      --typecode=2:0c01 \
      --change-name=2:MSR \
      "$DISK"
    sgdisk \
      --new=3:0:+"$WINDOWS_SIZE" \
      --typecode=3:0700 \
      --change-name=3:Windows \
      "$DISK"
    sgdisk \
      --new=4:0:+"$ROOT_SIZE" \
      --typecode=4:8300 \
      --change-name=4:NixOS \
      "$DISK"
    sgdisk \
      --new=5:0:-1G \
      --typecode=5:8300 \
      --change-name=5:tank \
      "$DISK"
  else
    sgdisk \
      --new=2:0:+"$ROOT_SIZE" \
      --typecode=2:8300 \
      --change-name=2:NixOS \
      "$DISK"
    sgdisk \
      --new=3:0:0 \
      --typecode=3:8300 \
      --change-name=3:tank \
      "$DISK"
  fi

  partprobe "$DISK"
  udevadm settle
}

create_existing_windows_layout() {
  local number

  if [ "$SEPARATE_ESP" -eq 1 ]; then
    number="$(next_part_number)"
    log "Creating NixOS ESP as partition $number"
    sgdisk \
      --new="${number}:0:+${ESP_SIZE}" \
      --typecode="$number:ef00" \
      --change-name="$number:NIXOS-ESP" \
      "$DISK"
    NIXOS_ESP="$(part_name "$DISK" "$number")"
  else
    NIXOS_ESP="$WIN_ESP"
  fi

  number="$(next_part_number)"
  log "Creating NixOS root as partition $number"
  sgdisk \
    --new="${number}:0:+${ROOT_SIZE}" \
    --typecode="$number:8300" \
    --change-name="$number:NixOS" \
    "$DISK"
  NIXOS_ROOT="$(part_name "$DISK" "$number")"

  number="$(next_part_number)"
  log "Creating ZFS partition as partition $number"
  sgdisk \
    --new="$number:0:0" \
    --typecode="$number:8300" \
    --change-name="$number:tank" \
    "$DISK"
  NIXOS_ZFS="$(part_name "$DISK" "$number")"

  partprobe "$DISK"
  udevadm settle
}

format_and_mount() {
  log "Formatting filesystems"

  if [ "$SEPARATE_ESP" -eq 1 ] || [ "$HAS_WINDOWS" -eq 0 ]; then
    wipefs -a "$NIXOS_ESP"
    mkfs.fat -F32 -n ESP "$NIXOS_ESP"
  else
    log "Keeping the existing Windows ESP at $NIXOS_ESP"
  fi

  wipefs -a "$NIXOS_ROOT"
  mkfs.ext4 -F -L nixos "$NIXOS_ROOT"

  if [ -n "$WINDOWS_PART" ]; then
    wipefs -a "$WINDOWS_PART" || true
  fi

  wipefs -a "$NIXOS_ZFS"

  mkdir -p /mnt
  mount "$NIXOS_ROOT" /mnt
  mkdir -p /mnt/boot
  mount "$NIXOS_ESP" /mnt/boot

  log "Creating ZFS pool tank"
  if zpool list -H -o name tank >/dev/null 2>&1; then
    die "ZFS pool 'tank' already exists; export or destroy it before installing"
  fi
  local zfs_dev
  zfs_dev="/dev/disk/by-partuuid/$(blkid -s PARTUUID -o value "$NIXOS_ZFS")"
  zpool create -f \
    -o ashift=12 \
    -O compression=lz4 \
    -O atime=off \
    -O xattr=sa \
    -O acltype=posixacl \
    -m /mnt/tank \
    tank "$zfs_dev"
  zpool set cachefile=none tank
}

copy_configuration() {
  log "Copying configuration to /mnt/etc/nixos"
  mkdir -p /mnt/etc/nixos

  local paths=(
    configuration.nix
    installation-mode.nix
    jotta-cli.nix
    nixos-control.nix
    desktop
    server
    install
    windows
  )

  local existing=()
  local path
  for path in "${paths[@]}"; do
    if [ -e "$REPO_DIR/$path" ]; then
      existing+=("$path")
    fi
  done

  tar -C "$REPO_DIR" \
    --exclude='server/target' \
    --exclude='windows/work' \
    --exclude='windows/out' \
    -cf - "${existing[@]}" \
    | tar -C /mnt/etc/nixos -xf -

  log "Generating hardware-configuration.nix"
  nixos-generate-config --root /mnt --show-hardware-config \
    > /mnt/etc/nixos/hardware-configuration.nix
}

write_mode_file() {
  log "Writing installation-mode.nix"
  local mode_file="/mnt/etc/nixos/installation-mode.nix"
  local iso_copied=0

  if [ "$MODE" = "vm" ] && [ -n "$WINDOWS_ISO" ]; then
    [ -f "$WINDOWS_ISO" ] || die "Windows ISO not found: $WINDOWS_ISO"
    log "Copying Windows ISO to /mnt$VM_ISO_TARGET"
    mkdir -p "/mnt$(dirname "$VM_ISO_TARGET")"
    cp "$WINDOWS_ISO" "/mnt$VM_ISO_TARGET"
    iso_copied=1
  fi

  {
    printf '{ ... }:\n\n{\n'
    printf '  myInstall.mode = "%s";\n' "$MODE"

    if [ -n "$HOSTNAME" ]; then
      printf '  networking.hostName = "%s";\n' "$HOSTNAME"
    fi

    printf '  myInstall.windows.toolchain = "%s";\n' "$WINDOWS_TOOLCHAIN"
    printf '  myInstall.windows.user = "%s";\n' "$USER_NAME"

    if [ "$MODE" = "vm" ]; then
      printf '  myInstall.vm.user = "%s";\n' "$USER_NAME"
      if [ "$iso_copied" -eq 1 ]; then
        printf '  myInstall.vm.iso = "%s";\n' "$VM_ISO_TARGET"
      fi
    fi

    if [ "$MODE" = "dual" ]; then
      if [ "$SEPARATE_ESP" -eq 1 ]; then
        printf '  myInstall.dualBoot.separateEsp = true;\n'
      else
        printf '  myInstall.dualBoot.separateEsp = false;\n'
      fi
      printf '  myInstall.dualBoot.windowsEfiDeviceHandle = null;\n'
      printf '  myInstall.dualBoot.rtcLocalTime = true;\n'
    fi

    if ! grep -q '"/mnt/tank"' /mnt/etc/nixos/hardware-configuration.nix; then
      cat <<'EOF'
  fileSystems."/mnt/tank" = {
    device = "tank";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };
EOF
    fi

    printf '}\n'
  } > "$mode_file"
}

confirm_apply() {
  [ "$APPLY" -eq 1 ] || return 0
  [ "$YES" -eq 1 ] && return 0

  local word="ERASE"
  if [ "$HAS_WINDOWS" -eq 1 ] && [ "$MODE" = "dual" ]; then
    word="INSTALL"
  fi

  printf '\n'
  warn "This will write to $DISK."
  if [ "$HAS_WINDOWS" -eq 1 ] && [ "$MODE" = "dual" ]; then
    warn "Existing Windows partitions are preserved, but partitioning mistakes are permanent."
  else
    warn "ALL DATA ON $DISK WILL BE DESTROYED."
  fi
  read -r -p "Type $word to continue: " answer
  [ "$answer" = "$word" ] || die "aborted"
}

run_install() {
  if [ "$NO_INSTALL" -eq 1 ]; then
    log "Skipping nixos-install (--no-install)"
    return
  fi

  log "Running nixos-install"
  nixos-install --root /mnt --no-root-passwd
  sync
}

print_next_steps() {
  cat <<EOF

Installation complete.

Next steps:
  - Reboot and remove the installer media.
  - Change the desktop user password: passwd $USER_NAME
    (the repository ships with a placeholder password).

EOF

  case "$MODE" in
    vm)
      cat <<EOF
VM mode:
  - The Windows ISO is at $VM_ISO_TARGET (if --windows-iso was used).
  - Create the VM as root:
      sudo windows-vm-create --iso $VM_ISO_TARGET
  - Or open virt-manager and create a Windows 11 VM manually.
  - The VM gets a virtual TPM and UEFI firmware, which Windows 11 needs.

EOF
      ;;
    dual)
      if [ "$HAS_WINDOWS" -eq 1 ]; then
        cat <<EOF
Dual-boot mode (Windows already installed):
  - systemd-boot should list Windows automatically because it shares the
    Windows ESP.
  - Check with: bootctl status
  - If Windows does not appear, run: sudo nixos-rebuild boot

EOF
      else
        cat <<EOF
Dual-boot mode (NixOS installed first):
  - The Windows partition is $WINDOWS_PART and is intentionally unformatted.
  - Boot the Windows 11 ISO and install into that partition.
  - Windows Setup will add its boot manager to the shared ESP.
  - After Windows boots once, boot NixOS and run:
      sudo nixos-rebuild boot
    so systemd-boot regenerates its menu and detects Windows.

EOF
      fi

      if [ "$SEPARATE_ESP" -eq 1 ]; then
        cat <<EOF
  - NixOS has its own ESP, so Windows is not auto-detected.  To add a
    systemd-boot entry:
      1. Reboot and choose "EDK2 UEFI Shell".
      2. Run: map -c
      3. Find the handle whose \\EFI directory contains Microsoft, for example
         HD0b1, and test: HD0b1:\\EFI\\Microsoft\\Boot\\Bootmgfw.efi
      4. Set myInstall.dualBoot.windowsEfiDeviceHandle = "HD0b1"; in
         /etc/nixos/installation-mode.nix and run sudo nixos-rebuild boot.
    Windows also remains selectable from the firmware boot menu.

EOF
      fi
      ;;
  esac

  cat <<EOF
Bootloader and Windows notes:
  - Disable Windows Fast Startup before dual booting.
  - If BitLocker is enabled, suspend it before changing the boot order and
    keep the recovery key available.
  - NixOS uses systemd-boot; Secure Boot needs lanzaboote.  Otherwise disable
    Secure Boot in the firmware.

Read install/README.md for the full walkthrough.
EOF
}

main() {
  parse_args "$@"
  check_environment
  select_mode
  validate_mode
  select_disk
  validate_disk
  select_windows_toolchain
  validate_windows_toolchain

  detect_windows

  if [ "$MODE" = "dual" ]; then
    if [ -z "$DUAL_ORDER" ]; then
      if [ "$HAS_WINDOWS" -eq 1 ]; then
        DUAL_ORDER="windows-first"
      else
        DUAL_ORDER="nixos-first"
      fi
    fi

    case "$DUAL_ORDER" in
      windows-first)
        [ "$HAS_WINDOWS" -eq 1 ] \
          || die "no Windows installation detected; install Windows first or use --dual-order nixos-first"
        plan_existing_windows
        ;;
      nixos-first)
        if [ "$HAS_WINDOWS" -eq 1 ]; then
          die "Windows already exists on $DISK; use --dual-order windows-first"
        fi
        validate_sizes
        plan_fresh_layout 1
        ;;
      *)
        die "invalid --dual-order: $DUAL_ORDER"
        ;;
    esac
  else
    validate_sizes
    plan_fresh_layout 0
  fi

  log "Windows ISO build toolchain: $WINDOWS_TOOLCHAIN"

  if [ "$APPLY" -eq 0 ]; then
    cat <<EOF

Dry run.  Nothing was written.

Re-run with --apply to perform the installation.
EOF
    return
  fi

  confirm_apply

  case "$MODE" in
    nixos | vm)
      create_fresh_layout 0
      ;;
    dual)
      if [ "$HAS_WINDOWS" -eq 1 ]; then
        create_existing_windows_layout
      else
        create_fresh_layout 1
      fi
      ;;
  esac

  format_and_mount
  copy_configuration
  write_mode_file
  run_install
  print_next_steps
}

main "$@"
