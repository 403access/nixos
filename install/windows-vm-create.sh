#!/usr/bin/env bash
#
# Create a performance-tuned Windows 11 VM with libvirt/QEMU.
#
# This helper is installed by install/default.nix when myInstall.mode = "vm".
# It is intentionally small: virt-manager remains the full management UI.
#
# Defaults are chosen for throughput on a normal workstation:
#   - VirtIO disk (virtio-blk) and VirtIO network, not SATA/e1000e
#   - host-passthrough CPU plus Hyper-V enlightenments
#   - io_uring with cache=none, TRIM/discard on
#   - UEFI + Secure Boot + vTPM, which Windows 11 expects anyway
#
# The disk is a normal file on the NVMe root.  qcow2 is the safe default;
# --raw avoids copy-on-write overhead.  Keep it off tank: that is an HDD
# mirror at 81% capacity.  Never run the installer against a disk that holds
# `tank`; it now refuses to do so.
set -euo pipefail

name="windows11"
iso="${MYINSTALL_VM_ISO:-}"
memory="${MYINSTALL_VM_MEMORY:-8192}"
vcpus="${MYINSTALL_VM_VCPUS:-4}"
disk_size="${MYINSTALL_VM_DISK_SIZE:-80G}"
disk_dir="${MYINSTALL_VM_DISK_DIR:-/var/lib/libvirt/images}"
disk_format="qcow2"
virtio_iso=""
use_virtio=auto
secure_boot=1
hugepages=0
connect="qemu:///system"

usage() {
  cat <<'EOF'
Usage: sudo windows-vm-create [options]

Create and start a Windows 11 VM.

Options:
  --name NAME          VM name (default: windows11)
  --iso PATH           Windows 11 ISO (default: myInstall.vm.iso or search)
  --memory MiB         Guest memory (default: 8192)
  --vcpus N            Guest vCPUs (default: 4; use host threads, not all)
  --disk-size SIZE     Disk size in GiB, e.g. 120 or 120G (default: 80G)
  --disk-dir PATH      Directory for the disk image
  --raw                Create a raw image instead of qcow2 (faster on ZFS/LVM)
  --virtio             Force VirtIO even without virtio-win ISO (install
                       will not see the disk; only use with a driver CD)
  --no-virtio          Fall back to SATA + e1000e (slow, last resort)
  --virtio-iso PATH    virtio-win ISO (default: auto-detect)
  --secure-boot        Enable Secure Boot in the VM firmware (default)
  --no-secure-boot     Disable Secure Boot
  --hugepages          Back guest memory with 2 MiB hugepages (requires
                       myInstall.vm.hugepages = true and a reboot)
  --connect URI        libvirt URI (default: qemu:///system)
  -h, --help           Show this help

After creation:
  virsh --connect qemu:///system list --all
  virt-manager --connect qemu:///system

Performance notes:
  - VirtIO needs the virtio-win driver CD during Setup.  The official ISO is
    picked up from the nix store when `virtio-win` is installed.
  - With only an integrated Intel GPU there is no PCI passthrough.  The guest
    uses virtio-gpu; expect fast 2D and software 3D, not gaming performance.
  - Keep the disk on the NVMe root (the default, /var/lib/libvirt/images).
    tank is a mirror of two HDDs at 81% capacity; a guest disk there is slow.
    Use --raw to avoid qcow2 overhead.  Never run install/install.sh against
    a disk that holds tank.
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
    --raw)
      disk_format="raw"
      shift
      ;;
    --virtio)
      use_virtio=on
      shift
      ;;
    --no-virtio)
      use_virtio=off
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
    --no-secure-boot)
      secure_boot=0
      shift
      ;;
    --hugepages)
      hugepages=1
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

# virtio-win ships the storage and network drivers Windows Setup needs.  It is
# installed by configuration.nix (`virtio-win`), so try the usual paths.
if [ -z "$virtio_iso" ]; then
  for candidate in \
    /run/current-system/sw/share/virtio-win/virtio-win.iso \
    /var/lib/libvirt/images/virtio-win.iso \
    /etc/nixos/windows/virtio-win.iso; do
    if [ -f "$candidate" ]; then
      virtio_iso="$candidate"
      break
    fi
  done
fi

if [ "$use_virtio" = "auto" ]; then
  if [ -n "$virtio_iso" ] && [ -f "$virtio_iso" ]; then
    use_virtio=on
  else
    use_virtio=off
    printf 'windows-vm-create: virtio-win ISO not found, falling back to SATA\n' >&2
    printf 'windows-vm-create: install virtio-win or pass --virtio-iso PATH for full speed\n' >&2
  fi
fi

if [ "$use_virtio" = "on" ]; then
  [ -n "$virtio_iso" ] || die "--virtio requires a virtio-win ISO (--virtio-iso PATH)"
  [ -f "$virtio_iso" ] || die "virtio-win ISO not found: $virtio_iso"
fi

if [ "$hugepages" -eq 1 ]; then
  free_huge="$(awk '/^HugePages_Free:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)"
  free_huge="${free_huge:-0}"
  if [ "$free_huge" -eq 0 ]; then
    die "--hugepages needs reserved hugepages.
       Set myInstall.vm.hugepages = true; in /etc/nixos/installation-mode.nix,
       run sudo nixos-rebuild switch, reboot, and check /proc/meminfo."
  fi
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
disk_path="$disk_dir/$name.$disk_format"
if [ -e "$disk_path" ]; then
  die "disk already exists: $disk_path"
fi

if [ "$use_virtio" = "on" ]; then
  disk_bus="virtio"
  net_model="virtio"
else
  disk_bus="sata"
  net_model="e1000e"
fi

# NixOS exposes OVMF through /run/libvirt/nix-ovmf (see the libvirtd module's
# qemu.conf nvram pairs).  Firmware autoselection needs descriptor JSONs that
# NixOS does not install, so point libvirt at the explicit pflash files.  The
# .ms variants carry the Microsoft keys and are the Secure Boot pair.
ovmf_dir="/run/libvirt/nix-ovmf"
ovmf_code="$ovmf_dir/OVMF_CODE.fd"
ovmf_vars="$ovmf_dir/OVMF_VARS.fd"
loader_secure="no"
if [ "$secure_boot" -eq 1 ]; then
  # OVMFFull builds its plain OVMF_CODE.fd with SECURE_BOOT_ENABLE, and the
  # .ms name is only a symlink to it.  Some builds ship the symlink dangling,
  # so prefer it when it resolves and fall back to the plain CODE otherwise.
  ovmf_code="$ovmf_dir/OVMF_CODE.ms.fd"
  [ -r "$ovmf_code" ] || ovmf_code="$ovmf_dir/OVMF_CODE.fd"
  ovmf_vars="$ovmf_dir/OVMF_VARS.ms.fd"
  loader_secure="yes"
fi

[ -r "$ovmf_code" ] && [ -r "$ovmf_vars" ] \
  || die "OVMF firmware not found in $ovmf_dir (Secure Boot needs OVMF_VARS.ms.fd); install an OVMF with Microsoft keys, for example pkgs.OVMFFull.fd"

boot_args="loader=$ovmf_code,loader.readonly=yes,loader.type=pflash,nvram.template=$ovmf_vars,loader_secure=$loader_secure"

# VirtIO + host-passthrough + Hyper-V enlightenments.  These are what make a
# Windows guest feel local: paravirtualised timer/IPI/TLB, no CPU emulation,
# and no memory balloon stealing pages under load.
features="smm.state=on"
features+=",hyperv.relaxed.state=on,hyperv.vapic.state=on"
features+=",hyperv.spinlocks.state=on,hyperv.spinlocks.retries=8191"
features+=",hyperv.vpindex.state=on,hyperv.runtime.state=on"
features+=",hyperv.synic.state=on,hyperv.stimer.state=on"
features+=",hyperv.reset.state=on,hyperv.frequencies.state=on"
features+=",hyperv.tlbflush.state=on,hyperv.ipi.state=on"

# virt-install --disk size= takes GiB as a plain number, so accept the
# documented "120G"/"120GiB" spelling and strip the unit.
disk_size_gib="${disk_size%GiB}"
disk_size_gib="${disk_size_gib%gib}"
disk_size_gib="${disk_size_gib%G}"
disk_size_gib="${disk_size_gib%g}"
[[ "$disk_size_gib" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || die "--disk-size must be a number of GiB, for example 120 or 120G"

# driver.cache/io/discard are the current virt-install spellings; the short
# cache=/io= aliases still parse but are deprecated.
disk_opts="path=$disk_path,size=$disk_size_gib,format=$disk_format,bus=$disk_bus"
disk_opts+=",boot.order=2"
disk_opts+=",driver.cache=none,driver.io=io_uring,driver.discard=unmap"

# Windows 11 needs its own osinfo entry for sensible driver defaults; fall
# back to win10 on an older database instead of failing outright.
os_variant="win11"
if command -v osinfo-query >/dev/null 2>&1 \
  && ! osinfo-query os short-id=win11 >/dev/null 2>&1; then
  os_variant="win10"
fi

printf 'Creating %s\n' "$name"
printf '  ISO:      %s\n' "$iso"
printf '  Disk:     %s (%s, %s, %s)\n' "$disk_path" "$disk_size" "$disk_format" "$disk_bus"
printf '  Memory:   %s MiB%s\n' "$memory" "$([ "$hugepages" -eq 1 ] && printf ' (hugepages)')"
printf '  CPUs:     %s (host-passthrough)\n' "$vcpus"
printf '  Firmware: UEFI%s + vTPM 2.0\n' "$([ "$secure_boot" -eq 1 ] && printf ' Secure Boot')"

virt_install_args=(
  --connect "$connect"
  --name "$name"
  --os-variant "$os_variant"
  --memory "$memory"
  --vcpus "$vcpus"
  --cpu host-passthrough
  --machine q35
  --boot "$boot_args"
  --features "$features"
  --clock "offset=localtime,hypervclock_present=yes"
  --tpm "backend.type=emulator,backend.version=2.0"
  --disk "$disk_opts"
  --disk "path=$iso,device=cdrom,boot.order=1"
  --network "network=default,model=$net_model"
  --graphics "spice,listen=127.0.0.1"
  --video virtio
  --memballoon none
  --noautoconsole
)

if [ "$hugepages" -eq 1 ]; then
  virt_install_args+=(--memorybacking hugepages=yes)
fi

if [ "$use_virtio" = "on" ]; then
  virt_install_args+=(--disk "path=$virtio_iso,device=cdrom,boot.order=3")
fi

virt-install "${virt_install_args[@]}"

cat <<EOF

$name is starting.  Open the console with:

  virt-manager --connect $connect

virt-viewer is not installed; virt-manager is the full console.  For the
lightweight viewer use: nix-shell -p virt-viewer --run 'virt-viewer --connect $connect $name'

Boot order is Windows ISO (1), disk (2), virtio-win CD (3), so Setup starts
without picking a device in the firmware menu.  If the guest stops in the
TianoCore/OVMF boot manager anyway, choose the CD-ROM entry for the Windows
ISO, not the virtio-win one.  After Windows is installed, eject the install
ISO in virt-manager (View -> Details -> SATA CDROM 1 -> Disconnect), or with:
  virsh --connect $connect domblklist $name
  virsh --connect $connect change-media $name TARGET --eject

EOF

if [ "$use_virtio" = "on" ]; then
  cat <<EOF
VirtIO is enabled.  In Windows Setup:
  1. Choose "Load driver" > "Browse" > the virtio-win CD.
  2. Load the VirtIO SCSI or viostor driver, then select the disk.
  3. After installation, run virtio-win-guest-tools.exe from the CD.
     That installs the network, balloon-free, and graphics drivers.

EOF
else
  cat <<EOF
SATA fallback in use.  This works with any ISO but is significantly slower.
Recreate the VM with virtio-win installed for full VirtIO performance.

EOF
fi

cat <<EOF
Secure Boot is $( [ "$secure_boot" -eq 1 ] && printf 'on' || printf 'off' ).
The disk stays at $disk_path and is never reformatted by this helper.
EOF