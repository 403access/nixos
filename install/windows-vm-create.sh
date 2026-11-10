#!/usr/bin/env bash
#
# Create a Windows 11 VM with libvirt/QEMU.
#
# This helper is installed by install/default.nix when myInstall.mode = "vm".
# It is intentionally small: virt-manager remains the full management UI.
set -euo pipefail

name="windows11"
iso="${MYINSTALL_VM_ISO:-}"
memory="${MYINSTALL_VM_MEMORY:-8192}"
vcpus="${MYINSTALL_VM_VCPUS:-4}"
disk_size="${MYINSTALL_VM_DISK_SIZE:-80G}"
disk_dir="/var/lib/libvirt/images"
virtio_iso=""
use_virtio=0
secure_boot=0
connect="qemu:///system"

usage() {
  cat <<'EOF'
Usage: sudo windows-vm-create [options]

Create and start a Windows 11 VM.  The default disk is SATA so Windows Setup
does not need VirtIO drivers.  Pass --virtio to use a VirtIO disk; you must then
load the viostor driver from the virtio-win ISO during Setup.

Options:
  --name NAME          VM name (default: windows11)
  --iso PATH           Windows 11 ISO (default: myInstall.vm.iso or search)
  --memory MiB         Guest memory (default: 8192)
  --vcpus N            Guest vCPUs (default: 4)
  --disk-size SIZE     qcow2 disk size (default: 80G)
  --disk-dir PATH      Directory for the qcow2 disk
  --virtio             Use VirtIO for disk and network
  --virtio-iso PATH    virtio-win ISO (required with --virtio)
  --secure-boot        Enable Secure Boot in the VM firmware
  --connect URI        libvirt URI (default: qemu:///system)
  -h, --help           Show this help

After creation:
  virsh --connect qemu:///system list --all
  virt-manager --connect qemu:///system
EOF
}

die() {
  printf 'windows-vm-create: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name)
      name="${2:?--name needs a value}"
      shift 2
      ;;
    --iso)
      iso="${2:?--iso needs a value}"
      shift 2
      ;;
    --memory)
      memory="${2:?--memory needs a value}"
      shift 2
      ;;
    --vcpus)
      vcpus="${2:?--vcpus needs a value}"
      shift 2
      ;;
    --disk-size)
      disk_size="${2:?--disk-size needs a value}"
      shift 2
      ;;
    --disk-dir)
      disk_dir="${2:?--disk-dir needs a value}"
      shift 2
      ;;
    --virtio)
      use_virtio=1
      shift
      ;;
    --virtio-iso)
      virtio_iso="${2:?--virtio-iso needs a value}"
      shift 2
      ;;
    --secure-boot)
      secure_boot=1
      shift
      ;;
    --connect)
      connect="${2:?--connect needs a value}"
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

if [ "$(id -u)" -ne 0 ]; then
  die "run this as root, for example: sudo windows-vm-create --iso /path/to/Win11.iso"
fi

command -v virt-install >/dev/null 2>&1 \
  || die "virt-install is missing; rebuild with myInstall.mode = \"vm\""
command -v virsh >/dev/null 2>&1 \
  || die "virsh is missing; rebuild with myInstall.mode = \"vm\""

if [ -z "$iso" ]; then
  shopt -s nullglob
  candidates=(
    /var/lib/libvirt/images/Win11.iso
    /etc/nixos/windows/out/Win11-*.iso
  )
  for candidate in "${candidates[@]}"; do
    if [ -f "$candidate" ]; then
      iso="$candidate"
      break
    fi
  done
fi

[ -n "$iso" ] || die "no Windows ISO found; pass --iso PATH"
[ -f "$iso" ] || die "ISO not found: $iso"
[ -r "$iso" ] || die "ISO is not readable: $iso"

if [ "$use_virtio" -eq 1 ]; then
  [ -n "$virtio_iso" ] || die "--virtio requires --virtio-iso PATH"
  [ -f "$virtio_iso" ] || die "virtio-win ISO not found: $virtio_iso"
fi

if virsh --connect "$connect" dominfo "$name" >/dev/null 2>&1; then
  die "domain '$name' already exists; choose another --name or remove it first"
fi

# Make sure the default NAT network is active; the NixOS module also does this
# at boot, but a freshly rebuilt system may not have run the unit yet.
if ! virsh --connect "$connect" net-list --name | grep -qx default; then
  virsh --connect "$connect" net-start default || true
  virsh --connect "$connect" net-autostart default || true
fi

mkdir -p "$disk_dir"
disk_path="$disk_dir/$name.qcow2"
if [ -e "$disk_path" ]; then
  die "disk already exists: $disk_path"
fi

if [ "$use_virtio" -eq 1 ]; then
  disk_bus="virtio"
  net_model="virtio"
else
  disk_bus="sata"
  net_model="e1000e"
fi

boot_args="uefi"
if [ "$secure_boot" -eq 1 ]; then
  boot_args="uefi,secure=on"
fi

printf 'Creating %s\n' "$name"
printf '  ISO:    %s\n' "$iso"
printf '  Disk:   %s (%s, %s)\n' "$disk_path" "$disk_size" "$disk_bus"
printf '  Memory: %s MiB, %s vCPU(s)\n' "$memory" "$vcpus"

virt_install_args=(
  --connect "$connect"
  --name "$name"
  --memory "$memory"
  --vcpus "$vcpus"
  --cpu host-passthrough
  --machine q35
  --boot "$boot_args"
  --features smm=on
  --tpm "backend.type=emulator,backend.version=2.0"
  --disk "path=$disk_path,size=$disk_size,format=qcow2,bus=$disk_bus"
  --cdrom "$iso"
  --network "network=default,model=$net_model"
  --graphics spice
  --video qxl
  --noautoconsole
)

if [ "$use_virtio" -eq 1 ]; then
  virt_install_args+=(--disk "path=$virtio_iso,device=cdrom")
fi

virt-install "${virt_install_args[@]}"

cat <<EOF

$name is starting.  Open the console with:

  virt-manager --connect $connect
  virsh --connect $connect console $name

EOF

if [ "$use_virtio" -eq 1 ]; then
  cat <<EOF
VirtIO disk selected.  In Windows Setup, choose "Load driver" and select the
viostor driver from the virtio-win CD before selecting the disk.
EOF
fi
