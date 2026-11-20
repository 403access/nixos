#!/usr/bin/env bash
#
# agent-vm - run an OCI image inside a KVM microVM.
#
# krunvm (libkrun) boots a separate Linux kernel per sandbox, so a process
# inside cannot see or touch the host kernel, /proc, /sys, the ZFS pool, the
# libvirt disks or the Docker daemon.  The guest sees exactly one directory
# (the workspace) and, if you ask for them, published ports.
#
# It runs as root because KVM and buildah need it.  Root inside the guest is
# not root on the host.
set -euo pipefail

default_cpus="${MY_SANDBOX_CPUS:-4}"
default_mem="${MY_SANDBOX_MEM:-4096}"
default_image="${MY_SANDBOX_IMAGE:-docker.io/library/debian:bookworm-slim}"
workspace_root="${MY_SANDBOX_WORKSPACES:-/var/lib/agent-workspaces}"

usage() {
  cat <<'EOF'
Usage: sudo agent-vm [run] [options] [-- COMMAND [ARG...]]
       sudo agent-vm list
       sudo agent-vm rm NAME

Run an OCI image in a KVM microVM (libkrun via krunvm).  The guest has its
own kernel and sees only the workspace volume and published ports.

Options:
  -w, --workspace DIR   Host directory exposed at /workspace (default: $PWD)
      --name NAME       microVM name (default: derived from the workspace)
      --image IMAGE     OCI image (default: debian:bookworm-slim)
      --cpus N          vCPUs, 1-8 (default: 4)
      --mem MiB         RAM, 256-16384 (default: 4096)
      --port H:G        Publish guest port G on host port H (repeatable)
      --env K=V         Environment variable for the guest (repeatable)
      --online          Give the guest network access (host socket passthrough)
      --offline         No guest networking (default; strongest isolation)
      --ephemeral       Delete the microVM when the command exits
  -h, --help            Show this help

The workspace is mounted read-write.  Sensitive paths (/, /etc, /boot, /nix,
/mnt/tank, /var/lib/libvirt, /var/lib/docker, /root) are refused.

Networking is off by default: the VMM runs in an empty network namespace, so
even libkrun's socket passthrough cannot reach the host, the LAN or tank.
Pass --online only when the guest really needs to download packages.

Examples:
  cd ~/src/agent-task && sudo agent-vm --cpus 6 --mem 8192
  cd ~/src/agent-task && sudo agent-vm --ephemeral -- python3 -m pytest
  sudo agent-vm --workspace ~/src/web --port 8080:8080 -- my-server
EOF
}

die() {
  printf 'agent-vm: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "run as root, for example: sudo agent-vm ..."
}

is_sensitive() {
  case "$1" in
    / | /etc | /etc/* | /boot | /boot/* | /nix | /nix/* | /root | /root/*) return 0 ;;
    /mnt/tank | /mnt/tank/* | /var/lib/libvirt | /var/lib/libvirt/*) return 0 ;;
    /var/lib/docker | /var/lib/docker/* | /var/lib/containers | /var/lib/containers/*) return 0 ;;
    "$workspace_root" | "$workspace_root"/*) return 1 ;;
  esac
  return 1
}

check_number() {
  local value="$1" name="$2" min="$3" max="$4"
  case "$value" in
    '' | *[!0-9]*) die "$name must be a number" ;;
  esac
  [ "$value" -ge "$min" ] && [ "$value" -le "$max" ] \
    || die "$name must be between $min and $max"
}

subcommand="${1:-run}"
case "$subcommand" in
  list | ls)
    require_root
    exec krunvm list
    ;;
  rm | remove | delete)
    require_root
    vm_name="${2:?usage: sudo agent-vm rm NAME}"
    exec krunvm delete "$vm_name"
    ;;
  run | start)
    if [ "$#" -gt 0 ]; then shift; fi
    ;;
  -h | --help | help)
    usage
    exit 0
    ;;
  --*)
    :
    ;;
  *)
    die "unknown subcommand: $subcommand"
    ;;
esac

require_root

vm_name=""
workspace=""
cpus="$default_cpus"
mem="$default_mem"
image="$default_image"
ephemeral=0
offline=1
ports=()
envs=()
command_args=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -w | --workspace)
      workspace="${2:?-w needs a directory}"
      shift 2
      ;;
    --name)
      vm_name="${2:?--name needs a value}"
      shift 2
      ;;
    --image)
      image="${2:?--image needs a value}"
      shift 2
      ;;
    --cpus)
      cpus="${2:?--cpus needs a value}"
      shift 2
      ;;
    --mem)
      mem="${2:?--mem needs a value}"
      shift 2
      ;;
    --port)
      ports+=("${2:?--port needs H:G}")
      shift 2
      ;;
    --env)
      envs+=("${2:?--env needs K=V}")
      shift 2
      ;;
    --online)
      offline=0
      shift
      ;;
    --offline)
      offline=1
      shift
      ;;
    --ephemeral)
      ephemeral=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      command_args=("$@")
      break
      ;;
    *)
      command_args=("$@")
      break
      ;;
  esac
done

check_number "$cpus" "--cpus" 1 8
check_number "$mem" "--mem" 256 16384

[ -n "$workspace" ] || workspace="$PWD"
[ -d "$workspace" ] || die "workspace is not a directory: $workspace"
workspace="$(realpath "$workspace")"
is_sensitive "$workspace" && die "refusing to expose $workspace to a guest"

if [ -z "$vm_name" ]; then
  base="$(basename "$workspace")"
  base="$(printf '%s' "$base" | tr -c 'A-Za-z0-9_.-' '-')"
  vm_name="agent-${base:-workspace}"
fi
case "$vm_name" in
  [A-Za-z0-9]* ) ;;
  *) die "invalid name: $vm_name" ;;
esac
case "$vm_name" in
  *[!A-Za-z0-9_.-]*) die "invalid name: $vm_name" ;;
esac

if krunvm list 2>/dev/null | grep -qx -- "$vm_name"; then
  die "microVM '$vm_name' already exists; remove it with: sudo agent-vm rm $vm_name"
fi

port_args=()
for mapping in "${ports[@]}"; do
  host_port="${mapping%%:*}"
  guest_port="${mapping##*:}"
  [ "$host_port" != "$mapping" ] || die "--port needs HOST:GUEST, got $mapping"
  check_number "$host_port" "--port host" 1024 65535
  check_number "$guest_port" "--port guest" 1 65535
  port_args+=(--port "$mapping")
done

if [ "${#port_args[@]}" -gt 0 ] && [ "$offline" -eq 1 ]; then
  die "--port needs --online (published ports imply guest networking)"
fi

env_args=()
for entry in "${envs[@]}"; do
  case "$entry" in
    *=*) env_args+=(--env "$entry") ;;
    *) die "--env needs K=V, got $entry" ;;
  esac
done

printf 'agent-vm: %s\n' "$vm_name"
printf '  image:     %s\n' "$image"
printf '  workspace: %s -> /workspace\n' "$workspace"
printf '  resources: %s vCPU, %s MiB\n' "$cpus" "$mem"

krunvm create \
  --name "$vm_name" \
  --cpus "$cpus" \
  --mem "$mem" \
  --volume "$workspace:/workspace" \
  --workdir /workspace \
  "${port_args[@]}" \
  "$image"

if [ "$ephemeral" -eq 1 ]; then
  trap 'krunvm delete "$vm_name" >/dev/null 2>&1 || true' EXIT
fi

# krunvm 0.2.x parses "[FLAGS] NAME [COMMAND] [-- ARGS...]"; without the
# separator, arguments such as -c are treated as krunvm flags.
start_args=(krunvm start "${env_args[@]}" "$vm_name")
if [ "${#command_args[@]}" -gt 0 ]; then
  start_args+=("${command_args[0]}" -- "${command_args[@]:1}")
fi
if [ "$offline" -eq 1 ]; then
  # Empty network namespace: the VMM itself has no route to the host, so
  # libkrun's TSI networking cannot be used as an escape path.
  start_args=(unshare -n -- "${start_args[@]}")
fi

printf '  network:   %s\n' "$([ "$offline" -eq 1 ] && printf 'offline' || printf 'online')"

set +e
"${start_args[@]}"
status=$?
set -e

if [ "$ephemeral" -eq 1 ]; then
  krunvm delete "$vm_name" >/dev/null 2>&1 || true
else
  printf '\nagent-vm: microVM kept.  Re-run with: sudo agent-vm start %s\n' "$vm_name"
  printf 'agent-vm: remove it with: sudo agent-vm rm %s\n' "$vm_name"
fi

exit "$status"