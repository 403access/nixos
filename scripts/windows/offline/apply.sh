#!/usr/bin/env bash
# Apply the offline Search/Defender hardening to a shut-down Windows VM.
#
# The VM is shut down, the raw disk is attached with qemu-nbd, the SYSTEM and
# SOFTWARE hives are patched, the changes are verified, and the VM is started
# again.  Every patched hive is backed up first.
#
# Examples:
#   sudo ./apply.sh --mode defender
#   sudo ./apply.sh --mode search
#   sudo ./apply.sh --mode all --domain win11-stock --disk /var/lib/libvirt/images/win11-stock.raw
#
# Test mode (no root, no VM, no disk):
#   ./apply.sh --hive-dir /tmp/hives --windows-root /tmp/tree --mode all

set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=registry.sh
source "$here/registry.sh"

domain="win11-stock"
disk="/var/lib/libvirt/images/win11-stock.raw"
mode="all"
mountpoint="/mnt/win11-offline"
backup_dir="/root"
hive_dir=""
windows_root=""
start_vm=1
log="/tmp/offline-windows.log"

usage() {
    cat <<'EOF'
Usage: apply.sh [options]

  --mode defender|search|all   What to harden (default: all)
  --domain NAME                libvirt domain (default: win11-stock)
  --disk PATH                  raw disk image (default: /var/lib/libvirt/images/win11-stock.raw)
  --mount PATH                 mount point (default: /mnt/win11-offline)
  --backup-dir PATH            where hive backups are written (default: /root)
  --hive-dir PATH              test mode: directory containing SYSTEM and SOFTWARE
  --windows-root PATH          test mode: directory containing Windows/Program Files/ProgramData
  --no-start                   leave the VM shut off after patching
  --log PATH                   log file (default: /tmp/offline-windows.log)
  -h, --help                   show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode)
            mode="${2:-}"
            shift 2
            ;;
        --domain)
            domain="${2:-}"
            shift 2
            ;;
        --disk)
            disk="${2:-}"
            shift 2
            ;;
        --mount)
            mountpoint="${2:-}"
            shift 2
            ;;
        --backup-dir)
            backup_dir="${2:-}"
            shift 2
            ;;
        --hive-dir)
            hive_dir="${2:-}"
            shift 2
            ;;
        --windows-root)
            windows_root="${2:-}"
            shift 2
            ;;
        --no-start)
            start_vm=0
            shift
            ;;
        --log)
            log="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$mode" in
    defender|search|all) ;;
    *)
        echo "ERROR: --mode must be defender, search or all" >&2
        exit 2
        ;;
esac

mkdir -p "$(dirname "$log")"
exec > >(tee -a "$log") 2>&1

ts="$(date +%Y%m%d-%H%M%S)"
vm_was_running=0
vm_started=0
mounted=0
nbd_connected=0

cleanup() {
    set +e
    if [ "$mounted" -eq 1 ]; then
        umount "$mountpoint" 2>/dev/null || true
    fi
    if [ "$nbd_connected" -eq 1 ]; then
        qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1 || true
    fi
    if [ "$vm_was_running" -eq 1 ] && [ "$vm_started" -eq 0 ] && [ "$start_vm" -eq 1 ]; then
        state="$(virsh domstate "$domain" 2>/dev/null || true)"
        if [ "$state" != "running" ]; then
            virsh start "$domain" >/dev/null 2>&1 || true
        fi
    fi
}
trap cleanup EXIT

backup_hive() {
    local hive="$1" name="$2" backup
    backup="$backup_dir/${domain}-${name}-${ts}.bak"
    offline_backup_hive "$hive" "$backup"
    for ext in LOG1 LOG2; do
        if [ -f "$hive.$ext" ]; then
            cp -a "$hive.$ext" "$backup.$ext"
        fi
    done
}

run_hive_mode() {
    local sys="$hive_dir/SYSTEM" soft="$hive_dir/SOFTWARE" root="${windows_root:-$hive_dir}"
    [ -f "$sys" ] || { echo "ERROR: missing $sys" >&2; exit 1; }
    [ -f "$soft" ] || { echo "ERROR: missing $soft" >&2; exit 1; }

    echo "== offline $mode (hive mode): $ts =="
    echo "SYSTEM: $sys"
    echo "SOFTWARE: $soft"
    echo "Windows root: $root"

    case "$mode" in
        defender)
            offline_patch_defender "$sys" "$soft" "$root"
            offline_verify_defender "$sys" "$soft" "$root"
            ;;
        search)
            offline_patch_search "$sys" "$root"
            offline_verify_search "$sys" "$root"
            ;;
        all)
            offline_patch_defender "$sys" "$soft" "$root"
            offline_patch_search "$sys" "$root"
            offline_verify_defender "$sys" "$soft" "$root"
            offline_verify_search "$sys" "$root"
            ;;
    esac
    echo "Done (hive mode)."
}

run_vm_mode() {
    [ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo) for VM mode" >&2; exit 1; }
    for tool in virsh qemu-nbd hivexregedit; do
        command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing $tool" >&2; exit 1; }
    done

    echo "== offline $mode: $ts =="
    state="$(virsh domstate "$domain" 2>/dev/null || true)"
    echo "Initial domain state: $state"
    if [ "$state" = "running" ]; then
        vm_was_running=1
        echo "Shutting down $domain ..."
        virsh shutdown "$domain" >/dev/null || true
        for _ in $(seq 1 90); do
            state="$(virsh domstate "$domain" 2>/dev/null || true)"
            [ "$state" = "shut off" ] && break
            sleep 2
        done
    fi
    state="$(virsh domstate "$domain" 2>/dev/null || true)"
    if [ "$state" != "shut off" ]; then
        echo "ERROR: domain is '$state', not 'shut off'; aborting." >&2
        exit 1
    fi
    echo "Domain is shut off."

    modprobe -r nbd 2>/dev/null || true
    modprobe nbd max_part=8
    modprobe ntfs3 2>/dev/null || true
    qemu-nbd --connect=/dev/nbd0 --format=raw "$disk"
    nbd_connected=1
    sleep 1
    partx -a /dev/nbd0 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    lsblk -f /dev/nbd0 || true

    mkdir -p "$mountpoint"
    part=""
    while read -r name fstype; do
        [ "$fstype" = "ntfs" ] || continue
        candidate="/dev/$name"
        if mount -t ntfs3 -o ro "$candidate" "$mountpoint" 2>/dev/null ||
            mount.ntfs-3g -o ro "$candidate" "$mountpoint" 2>/dev/null; then
            if [ -f "$mountpoint/Windows/System32/config/SYSTEM" ]; then
                part="$candidate"
                echo "Windows partition: $part"
                break
            fi
            umount "$mountpoint" 2>/dev/null || true
        fi
    done < <(lsblk -ln -o NAME,FSTYPE /dev/nbd0)

    if [ -z "$part" ]; then
        echo "ERROR: no NTFS partition containing Windows\\System32\\config\\SYSTEM" >&2
        exit 1
    fi
    if [ -f "$mountpoint/hiberfil.sys" ]; then
        echo "ERROR: hiberfil.sys is present; disable hibernation/Fast Startup first." >&2
        echo "In Windows: powercfg /h off; shutdown /s /f /t 0" >&2
        exit 1
    fi

    umount "$mountpoint"
    mounted=0
    mount -t ntfs3 -o rw "$part" "$mountpoint" 2>/dev/null ||
        mount.ntfs-3g "$part" "$mountpoint"
    mounted=1
    if ! touch "$mountpoint/.winslim-write-test" 2>/dev/null; then
        echo "ERROR: NTFS partition is not writable." >&2
        exit 1
    fi
    rm -f "$mountpoint/.winslim-write-test"

    sys="$mountpoint/Windows/System32/config/SYSTEM"
    soft="$mountpoint/Windows/System32/config/SOFTWARE"
    [ -f "$sys" ] || { echo "ERROR: SYSTEM hive missing" >&2; exit 1; }
    [ -f "$soft" ] || { echo "ERROR: SOFTWARE hive missing" >&2; exit 1; }

    backup_hive "$sys" SYSTEM
    backup_hive "$soft" SOFTWARE

    case "$mode" in
        defender)
            offline_patch_defender "$sys" "$soft" "$mountpoint"
            offline_verify_defender "$sys" "$soft" "$mountpoint"
            ;;
        search)
            offline_patch_search "$sys" "$mountpoint"
            offline_verify_search "$sys" "$mountpoint"
            ;;
        all)
            offline_patch_defender "$sys" "$soft" "$mountpoint"
            offline_patch_search "$sys" "$mountpoint"
            offline_verify_defender "$sys" "$soft" "$mountpoint"
            offline_verify_search "$sys" "$mountpoint"
            ;;
    esac

    sync
    umount "$mountpoint"
    mounted=0
    qemu-nbd --disconnect /dev/nbd0 >/dev/null
    nbd_connected=0

    if [ "$start_vm" -eq 1 ]; then
        echo "Starting $domain ..."
        virsh start "$domain" >/dev/null
        vm_started=1
    fi
    echo "Done. Backups are in $backup_dir."
    echo "Log: $log"
}

if [ -n "$hive_dir" ]; then
    run_hive_mode
else
    run_vm_mode
fi