#!/usr/bin/env bash
#
# agent-vm - run an OCI image inside a KVM microVM with a per-sandbox network.
#
# krunvm (libkrun) boots a separate Linux kernel per sandbox, so a process
# inside cannot see or touch the host kernel, /proc, /sys, the ZFS pool, the
# libvirt disks or the Docker daemon.  On top of that, every VM runs its VMM in
# a dedicated network namespace connected to the host by a point-to-point veth
# pair.  The host firewall then:
#
#   * drops every new connection from the sandbox to the host,
#   * drops traffic between sandboxes,
#   * lets the host reach the sandbox (published ports, and the guest IP),
#   * optionally gives the sandbox internet access (but not the LAN).
#
# It runs as root because KVM, buildah, network namespaces and nftables need
# it.  Root inside the guest is not root on the host.
set -euo pipefail

default_cpus="${MY_SANDBOX_CPUS:-4}"
default_mem="${MY_SANDBOX_MEM:-4096}"
default_image="${MY_SANDBOX_IMAGE:-docker.io/library/debian:bookworm-slim}"
default_dns="${MY_SANDBOX_DNS:-1.1.1.1}"
workspace_root="${MY_SANDBOX_WORKSPACES:-/var/lib/agent-workspaces}"
shared_root="${MY_SANDBOX_SHARES:-/var/lib/agent-shares}"
state_root="${MY_SANDBOX_STATE:-/var/lib/agent-vm}"
run_root="${MY_SANDBOX_RUN:-/run/agent-vm}"
workspace_root="${workspace_root%/}"
shared_root="${shared_root%/}"
state_root="${state_root%/}"
run_root="${run_root%/}"
[ -n "$workspace_root" ] || workspace_root=/
[ -n "$shared_root" ] || shared_root=/
[ -n "$state_root" ] || state_root=/
[ -n "$run_root" ] || run_root=/
subnet_octet="${MY_SANDBOX_SUBNET:-213}"
internal_base="${MY_SANDBOX_INTERNAL_BASE:-20000}"
nft_table="agent_vm"

docker_init_src='#!/bin/sh
set -eu
if ! command -v dockerd >/dev/null 2>&1; then
  echo "agent-vm: --docker needs an image with dockerd (see sandbox/agent-base/)" >&2
  exit 127
fi
mkdir -p /var/log /sys/fs/cgroup
grep -q " /sys/fs/cgroup cgroup2 " /proc/mounts || mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true
extra=""
if [ -n "${AGENT_DOCKER_STORAGE_DRIVER:-}" ]; then
  extra="--storage-driver=$AGENT_DOCKER_STORAGE_DRIVER"
fi
dockerd --iptables=false --ip6tables=false --bridge=none $extra >/var/log/dockerd.log 2>&1 &
i=0
while [ ! -S /var/run/docker.sock ]; do
  i=$((i + 1))
  if [ "$i" -gt 100 ]; then
    echo "agent-vm: dockerd did not start; see /var/log/dockerd.log" >&2
    tail -n 20 /var/log/dockerd.log >&2 || true
    exit 1
  fi
  sleep 0.1
done
exec "$@"'

# Read-only bind mounts and per-run state live in /run; the VM definition
# (name, image, cpus, volumes) lives in krunvm's own config under /root.
# (Created after the root check so --help works as a normal user.)

usage() {
  cat <<'EOF'
Usage: sudo agent-vm run [options] [-- COMMAND [ARG...]]
       sudo agent-vm start [--detach] NAME
       sudo agent-vm stop NAME
       sudo agent-vm list
       sudo agent-vm logs NAME
       sudo agent-vm rm NAME
       sudo agent-vm gc

Run an OCI image in a KVM microVM (libkrun via krunvm).  Each sandbox has its
own kernel and its own network namespace.  The guest cannot initiate
connections to the host or to another sandbox; the host can reach the guest
through published ports and the guest IP.

Options:
  -w, --workspace DIR   Host directory exposed read-write at /workspace
                        (default: $PWD, must not be used by another sandbox)
      --name NAME       microVM name (default: derived from the workspace)
      --image IMAGE     OCI image (default: debian:bookworm-slim)
      --cpus N          vCPUs, 1-8 (default: 4)
      --mem MiB         RAM, 256-16384 (default: 4096)
      --share SPEC      Extra host folder at /share-NAME.  SPEC is
                        PATH, PATH:ro, NAME=PATH or NAME=PATH:ro.  Giving the
                        same PATH to two sandboxes is the explicit way to share
                        files between them.
      --port H:G        Publish guest TCP port G on 127.0.0.1:H (repeatable)
      --publish A:H:G   Publish guest TCP port G on host address A (repeatable);
                        A may be 0.0.0.0
      --env K=V         Environment variable for the guest command (repeatable).
                        Applied with `env`; ignored when no command is given.
      --docker          Start dockerd in the guest before COMMAND.  The image
                        must contain dockerd.  Containers should use the guest
                        network (--network host); see sandbox/agent-base/.
      --online          Give the guest internet access (not the host or LAN)
      --lan             With --online, also allow the LAN (never the host)
      --offline         No guest egress (default; strongest isolation)
      --detach          Leave the sandbox running in the background
      --ephemeral       Delete the microVM when the command exits
  -h, --help            Show this help

The workspace is mounted read-write.  Sensitive paths (/, /etc, /boot, /nix,
/root, /mnt/tank, /var/lib/libvirt, /var/lib/docker, /proc, /sys, /dev,
/var/lib/agent-vm) are refused.  A workspace already used by a running sandbox
is refused; use --share if sharing is intended.

Examples:
  cd ~/src/agent-task && sudo agent-vm --cpus 6 --mem 8192
  sudo agent-vm --name web --detach --port 8080:8080 -- my-server
  sudo agent-vm --online --ephemeral -- python3 -m pytest
  sudo agent-vm --share team=/srv/team --share docs=/srv/docs:ro
  sudo agent-vm --docker -- ./run-tests.sh
EOF
}

die() {
  printf 'agent-vm: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "run as root, for example: sudo agent-vm ..."
  # Keep krunvm's VM definitions in root's config regardless of how sudo
  # preserved the caller's HOME.
  export HOME="${MY_SANDBOX_HOME:-/root}"
  export XDG_CONFIG_HOME="$HOME/.config"
  mkdir -p "$state_root/state" "$run_root/log" "$run_root/pids" \
    "$run_root/busy" "$run_root/ro"
}

# The Docker bootstrap is a file, not a `sh -c` string: krunvm serializes the
# guest command into the kernel command line, where long quoted scripts do not
# survive.  It is exposed read-only at /agent-docker-init.
write_docker_init() {
  local dir="$state_root/docker-init"
  local ro="$run_root/ro/docker-init"
  mkdir -p "$dir" "$run_root/ro"
  printf '%s\n' "$docker_init_src" >"$dir/init.sh"
  chmod 0755 "$dir/init.sh"
  if ! mountpoint -q "$ro"; then
    mkdir -p "$ro"
    mount --bind "$dir" "$ro"
    mount -o remount,bind,ro "$ro" \
      || { umount "$ro" 2>/dev/null || true; die "could not make the docker init read-only"; }
  fi
}

valid_name() {
  case "$1" in
    '' | *[!A-Za-z0-9_.-]*) return 1 ;;
    [A-Za-z0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

is_sensitive() {
  case "$1" in
    / | /etc | /etc/* | /boot | /boot/* | /nix | /nix/* | /root | /root/*) return 0 ;;
    /mnt/tank | /mnt/tank/* | /var/lib/libvirt | /var/lib/libvirt/*) return 0 ;;
    /var/lib/docker | /var/lib/docker/* | /var/lib/containers | /var/lib/containers/*) return 0 ;;
    /proc | /proc/* | /sys | /sys/* | /dev | /dev/*) return 0 ;;
    /run | /run/* | /var/lib/agent-vm | /var/lib/agent-vm/*) return 0 ;;
    "$state_root" | "$state_root"/*) return 0 ;;
    "$workspace_root" | "$shared_root") return 0 ;;
    "$workspace_root"/* | "$shared_root"/*) return 1 ;;
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

state_file() { printf '%s/state/%s.conf\n' "$state_root" "$1"; }
ports_file() { printf '%s/state/%s.ports\n' "$state_root" "$1"; }
shares_file() { printf '%s/state/%s.shares\n' "$state_root" "$1"; }
pid_file() { printf '%s/state/%s.pid\n' "$state_root" "$1"; }
command_file() { printf '%s/state/%s.cmd\n' "$state_root" "$1"; }
env_file() { printf '%s/state/%s.env\n' "$state_root" "$1"; }
log_file() { printf '%s/log/%s.log\n' "$run_root" "$1"; }
socat_pid_file() { printf '%s/pids/%s.socat\n' "$run_root" "$1"; }
host_socat_pid_file() { printf '%s/pids/%s.hostsocat\n' "$run_root" "$1"; }

load_state() {
  local name="$1" file
  file="$(state_file "$name")"
  [ -f "$file" ] || return 1
  # shellcheck disable=SC1090
  . "$file"
  [ "${name:-}" = "$name" ]
}

save_state() {
  local name="$1"
  shift
  local file tmp created_value
  file="$(state_file "$name")"
  tmp="$file.tmp.$$"
  created_value="${created:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  {
    printf 'name=%q\n' "$name"
    printf 'idx=%q\n' "$idx"
    printf 'image=%q\n' "$image"
    printf 'cpus=%q\n' "$cpus"
    printf 'mem=%q\n' "$mem"
    printf 'dns=%q\n' "$dns"
    printf 'online=%q\n' "$online"
    printf 'lan=%q\n' "$lan"
    printf 'status=%q\n' "$status"
    printf 'ephemeral=%q\n' "$ephemeral"
    printf 'docker=%q\n' "$docker"
    printf 'workspace=%q\n' "$workspace"
    printf 'created=%q\n' "$created_value"
  } >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$file"
}

guest_ip() { printf '10.%s.%s.2\n' "$subnet_octet" "$1"; }
host_ip() { printf '10.%s.%s.1\n' "$subnet_octet" "$1"; }
host_veth() { printf 'sbxh%03d\n' "$1"; }
netns_name() { printf 'sbx-%s\n' "$1"; }

# --- nftables ---------------------------------------------------------------
#
# The ruleset is regenerated from the state files after every start/stop, so
# there are no incremental rule edits to drift or leak.  Only VMs whose state
# says "running" contribute interfaces and DNAT rules.

nft_rebuild() {
  local running="" online_wan="" online_lan="" offline=""
  local f name idx status online lan workspace rules
  rules="$run_root/nft.rules.$$"

  for f in "$state_root"/state/*.conf; do
    [ -e "$f" ] || continue
    unset name idx status online lan workspace
    # shellcheck disable=SC1090
    . "$f"
    [ "${status:-}" = "running" ] || continue

    local veth
    veth="$(host_veth "$idx")"
    running+="\"$veth\", "
    if [ "${online:-0}" = "1" ]; then
      if [ "${lan:-0}" = "1" ]; then
        online_lan+="\"$veth\", "
      else
        online_wan+="\"$veth\", "
      fi
    else
      offline+="\"$veth\", "
    fi
  done

  {
    printf 'table inet %s {\n' "$nft_table"
    if [ -n "$running" ]; then
      printf '  set running { type ifname; elements = { %s } }\n' "${running%, }"
    else
      printf '  set running { type ifname; }\n'
    fi
    if [ -n "$online_wan" ]; then
      printf '  set online_wan { type ifname; elements = { %s } }\n' "${online_wan%, }"
    else
      printf '  set online_wan { type ifname; }\n'
    fi
    if [ -n "$online_lan" ]; then
      printf '  set online_lan { type ifname; elements = { %s } }\n' "${online_lan%, }"
    else
      printf '  set online_lan { type ifname; }\n'
    fi
    if [ -n "$offline" ]; then
      printf '  set offline { type ifname; elements = { %s } }\n' "${offline%, }"
    else
      printf '  set offline { type ifname; }\n'
    fi
    printf '%s\n' \
      '  chain input {' \
      '    type filter hook input priority filter; policy accept;' \
      '    iifname @running ct state established,related accept' \
      '    iifname @running drop' \
      '  }' \
      '  chain forward {' \
      '    type filter hook forward priority filter; policy accept;' \
      '    iifname @running ip daddr 10.'"$subnet_octet"'.0.0/16 drop' \
      '    iifname @running ct state established,related accept' \
      '    iifname @online_wan ip daddr { 10.0.0.0/8, 100.64.0.0/10, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 127.0.0.0/8 } drop' \
      '    iifname @online_wan accept' \
      '    iifname @online_lan accept' \
      '    iifname @offline drop' \
      '  }' \
      '  chain postrouting {' \
      '    type nat hook postrouting priority srcnat; policy accept;' \
      "    ip saddr 10.$subnet_octet.0.0/16 masquerade" \
      '  }'
    printf '}\n'
  } >"$rules"

  local rc=0
  if nft list table inet "$nft_table" >/dev/null 2>&1; then
    { printf 'delete table inet %s\n' "$nft_table"; cat "$rules"; } | nft -f - || rc=$?
  else
    nft -f "$rules" || rc=$?
  fi
  rm -f "$rules"
  return "$rc"
}

# --- networking -------------------------------------------------------------

ipv4_available() { printf '%s' "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; }

alloc_idx() {
  local n used f
  mkdir -p "$run_root"
  exec 9>"$run_root/alloc.lock"
  flock -x 9
  used=" "
  for f in "$state_root"/state/*.conf; do
    [ -e "$f" ] || continue
    unset idx
    # shellcheck disable=SC1090
    . "$f"
    used+="${idx:-} "
  done
  for n in $(seq 1 254); do
    case "$used" in
      *" $n "*) continue ;;
    esac
    if ip link show "$(host_veth "$n")" >/dev/null 2>&1; then
      continue
    fi
    printf '%s\n' "$n"
    exec 9>&-
    return 0
  done
  exec 9>&-
  die "no free sandbox slot (254 in use)"
}

host_port_in_use() {
  ss -Htln 2>/dev/null | awk '{print $4}' | grep -Eq ":$1$"
}

published_port_in_use() {
  local wanted="$1" exclude="${2:-}" f addr hport gport iport conf base
  for f in "$state_root"/state/*.ports; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .ports)"
    [ "$base" = "$exclude" ] && continue
    conf="${f%.ports}.conf"
    [ -f "$conf" ] || continue
    grep -q '^status=running$' "$conf" || continue
    while IFS=$'\t' read -r addr hport gport iport; do
      [ "${hport:-}" = "$wanted" ] && return 0
    done <"$f"
  done
  return 1
}

setup_netns() {
  local name="$1" idx="$2" online="$3"
  local ns hostveth peerveth hip gip
  ns="$(netns_name "$name")"
  hostveth="$(host_veth "$idx")"
  peerveth="$(printf 'sbxs%03d' "$idx")"
  hip="$(host_ip "$idx")"
  gip="$(guest_ip "$idx")"

  ip netns del "$ns" >/dev/null 2>&1 || true
  ip link del "$hostveth" >/dev/null 2>&1 || true

  ip netns add "$ns"
  ip link add "$hostveth" type veth peer name "$peerveth"
  ip link set "$peerveth" netns "$ns"
  ip addr add "$hip/30" dev "$hostveth"
  ip link set "$hostveth" up

  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip link set "$peerveth" name eth0
  ip netns exec "$ns" ip addr add "$gip/30" dev eth0
  ip netns exec "$ns" ip link set eth0 up
  ip netns exec "$ns" sysctl -qw net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
  ip netns exec "$ns" sysctl -qw net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
  ip netns exec "$ns" ip -6 addr flush dev eth0 2>/dev/null || true
  ip netns exec "$ns" ip -6 addr flush dev lo 2>/dev/null || true

  if [ "$online" = "1" ]; then
    ip netns exec "$ns" ip route add default via "$hip"
  fi

  ip netns exec "$ns" ip -4 addr show >/dev/null
}

teardown_netns() {
  local name="$1" idx="$2"
  local ns hostveth
  ns="$(netns_name "$name")"
  hostveth="$(host_veth "$idx")"

  if [ -f "$(socat_pid_file "$name")" ]; then
    local spid
    while read -r spid; do
      [ -n "${spid:-}" ] && kill "$spid" >/dev/null 2>&1 || true
    done <"$(socat_pid_file "$name")"
    rm -f "$(socat_pid_file "$name")"
  fi
  if [ -f "$(host_socat_pid_file "$name")" ]; then
    local hpid
    while read -r hpid; do
      [ -n "${hpid:-}" ] && kill "$hpid" >/dev/null 2>&1 || true
    done <"$(host_socat_pid_file "$name")"
    rm -f "$(host_socat_pid_file "$name")"
  fi
  ip netns del "$ns" >/dev/null 2>&1 || true
  ip link del "$hostveth" >/dev/null 2>&1 || true
}

start_socat_forwards() {
  local name="$1" idx="$2"
  local ns gip pf addr hport gport iport
  ns="$(netns_name "$name")"
  gip="$(guest_ip "$idx")"
  pf="$(ports_file "$name")"
  [ -f "$pf" ] || return 0
  : >"$(socat_pid_file "$name")"
  : >"$(host_socat_pid_file "$name")"
  while IFS=$'\t' read -r addr hport gport iport; do
    [ -n "${addr:-}" ] || continue
    # TSI publishes the guest listener inside the network namespace on the
    # internal host port.  This relay exposes it on the veth address so the
    # host can reach it, regardless of whether the guest bound 0.0.0.0 or
    # 127.0.0.1.
    ip netns exec "$ns" socat \
      "TCP-LISTEN:$hport,bind=$gip,fork,reuseaddr" \
      "TCP:127.0.0.1:$iport" >/dev/null 2>&1 &
    printf '%s\n' "$!" >>"$(socat_pid_file "$name")"

    # The host-facing listener is a plain proxy, not a DNAT rule: the host
    # connects to the sandbox as a normal routed client, and no packet ever
    # carries a loopback source address into the guest.
    socat \
      "TCP-LISTEN:$hport,bind=$addr,fork,reuseaddr" \
      "TCP:$gip:$hport" >/dev/null 2>&1 &
    printf '%s\n' "$!" >>"$(host_socat_pid_file "$name")"
  done <"$pf"
}

# --- shares -----------------------------------------------------------------

busy_key() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

workspace_conflict() {
  local name="$1" path="$2" f other_name other_path
  mkdir -p "$run_root/busy"
  for f in "$run_root"/busy/*; do
    [ -e "$f" ] || continue
    IFS=$'\t' read -r other_name other_path _ <"$f" || continue
    [ "${other_name:-}" = "$name" ] && continue
    case "$path/" in
      "$other_path"/*)
        printf '%s\n' "$other_name"
        return 0
        ;;
    esac
    case "$other_path/" in
      "$path"/*)
        printf '%s\n' "$other_name"
        return 0
        ;;
    esac
  done
  return 1
}

mark_workspace() {
  local name="$1" path="$2"
  mkdir -p "$run_root/busy"
  printf '%s\t%s\t%s\n' "$name" "$path" "$$" \
    >"$run_root/busy/$(busy_key "$path")"
}

unmark_workspace() {
  local path="$1" f
  f="$run_root/busy/$(busy_key "$path")"
  rm -f "$f"
}

prepare_shares() {
  local name="$1" sf sname spath sro sguest n=0 bind
  sf="$(shares_file "$name")"
  [ -f "$sf" ] || return 0
  mkdir -p "$run_root/ro/$name"
  while IFS=$'\t' read -r sname spath sro sguest; do
    [ -n "${sname:-}" ] || continue
    if [ "$sro" = "1" ]; then
      bind="$run_root/ro/$name/$n"
      mkdir -p "$bind"
      if ! mountpoint -q "$bind"; then
        mount --bind "$spath" "$bind"
        mount -o remount,bind,ro "$bind" \
          || { umount "$bind" 2>/dev/null || true; die "could not make $spath read-only"; }
      fi
    fi
    n=$((n + 1))
  done <"$sf"
}

volume_source() {
  local name="$1" sname="$2" spath="$3" sro="$4" n="$5"
  if [ "$sro" = "1" ]; then
    printf '%s/ro/%s/%s\n' "$run_root" "$name" "$n"
  else
    printf '%s\n' "$spath"
  fi
}

cleanup_shares() {
  local name="$1" sf sname spath sro sguest n=0 bind
  sf="$(shares_file "$name")"
  [ -f "$sf" ] || return 1
  while IFS=$'\t' read -r sname spath sro sguest; do
    [ -n "${sname:-}" ] || continue
    if [ "$sro" = "1" ]; then
      bind="$run_root/ro/$name/$n"
      mountpoint -q "$bind" && umount "$bind" 2>/dev/null || true
    fi
    n=$((n + 1))
  done <"$sf"
  rmdir "$run_root/ro/$name" 2>/dev/null || true
}

# --- lifecycle --------------------------------------------------------------

cleanup_run() {
  local name="$1"
  set +e
  [ -f "$(state_file "$name")" ] || return 0
  load_state "$name" || return 0

  if [ "${status:-}" = "starting" ]; then
    teardown_netns "$name" "$idx"
    cleanup_shares "$name" || true
    unmark_workspace "${workspace:-}" 2>/dev/null || true
    rm -f "$(state_file "$name")" "$(ports_file "$name")" "$(shares_file "$name")" "$(command_file "$name")" "$(env_file "$name")" "$(pid_file "$name")"
    nft_rebuild
    return 0
  fi

  teardown_netns "$name" "$idx"
  cleanup_shares "$name" || true
  unmark_workspace "${workspace:-}" 2>/dev/null || true
  rm -f "$(pid_file "$name")"

  if [ "${status:-}" = "running" ]; then
    status="stopped"
    save_state "$name"
  fi
  if [ "${ephemeral:-0}" = "1" ] && [ -f "$(state_file "$name")" ]; then
    krunvm delete "$name" >/dev/null 2>&1 || true
    rm -f "$(state_file "$name")" "$(ports_file "$name")" "$(shares_file "$name")" "$(command_file "$name")" "$(env_file "$name")"
  fi
  nft_rebuild
}

run_vm() {
  local name="$1"
  local ns
  local -a cmd start_cmd
  ns="$(netns_name "$name")"
  load_state "$name" || die "no state for $name"

  if [ "$docker" = "1" ]; then
    if [ "${#command_args[@]}" -eq 0 ]; then
      command_args=(/bin/sh)
    fi
    cmd=(/bin/sh /agent-docker-init/init.sh "${command_args[@]}")
  else
    cmd=("${command_args[@]}")
  fi

  if [ "${#cmd[@]}" -gt 0 ]; then
    if [ "${#guest_env[@]}" -gt 0 ]; then
      # This krunvm version has no `start --env`; `env` in the guest is the
      # portable equivalent and keeps the values out of the host environment.
      start_cmd=(krunvm start "$name" env -- "${guest_env[@]}" "${cmd[@]}")
    else
      start_cmd=(krunvm start "$name" "${cmd[0]}" -- "${cmd[@]:1}")
    fi
  else
    start_cmd=(krunvm start "$name")
  fi

  status="running"
  save_state "$name"
  nft_rebuild
  start_socat_forwards "$name" "$idx"

  mkdir -p "$run_root/log"
  if [ "$detach" = "1" ]; then
    (
      # Detach from the caller's stdout/stderr so a job runner or the API's
      # command wrapper sees EOF immediately.  Everything the sandbox prints
      # goes to its log file instead.
      exec </dev/null >>"$(log_file "$name")" 2>&1
      trap '' HUP
      ip netns exec "$ns" "${start_cmd[@]}" &
      child=$!
      trap 'kill "$child" >/dev/null 2>&1 || true' TERM INT
      set +e
      wait "$child"
      rc=$?
      set -e
      cleanup_run "$name"
      exit "$rc"
    ) &
    printf '%s\n' "$!" >"$(pid_file "$name")"
    printf 'agent-vm: %s running in the background (pid %s)\n' "$name" "$!"
    printf 'agent-vm: logs: sudo agent-vm logs %s; stop: sudo agent-vm stop %s\n' "$name" "$name"
    return 0
  fi

  ip netns exec "$ns" "${start_cmd[@]}" &
  child=$!
  printf '%s\n' "$child" >"$(pid_file "$name")"
  trap 'kill "$child" >/dev/null 2>&1 || true' TERM INT
  set +e
  wait "$child"
  rc=$?
  set -e
  cleanup_run "$name"
  exit "$rc"
}

start_existing() {
  name="$1"
  load_state "$name" || die "no such sandbox: $name"
  [ "$status" = "stopped" ] || die "$name is already $status"
  [ -d "$workspace" ] || die "workspace no longer exists: $workspace"

  if krunvm list 2>/dev/null | grep -qx -- "$name"; then
    : # krunvm still knows this VM
  else
    die "microVM $name no longer exists; re-create it with: sudo agent-vm run --name $name ..."
  fi

  local conflict
  if conflict="$(workspace_conflict "$name" "$workspace")"; then
    die "workspace $workspace is already used by sandbox $conflict"
  fi

  local pf addr hport gport iport
  pf="$(ports_file "$name")"
  if [ -f "$pf" ]; then
    while IFS=$'\t' read -r addr hport gport iport; do
      [ -n "${addr:-}" ] || continue
      host_port_in_use "$hport" && die "host port $hport is already in use"
      published_port_in_use "$hport" "$name" && die "port $hport is already published by another sandbox"
    done <"$pf"
  fi

  setup_netns "$name" "$idx" "$online"
  prepare_shares "$name"
  [ "$docker" = "1" ] && write_docker_init
  mark_workspace "$name" "$workspace"
  trap 'cleanup_run "$name"' EXIT
  command_args=()
  if [ -f "$(command_file "$name")" ]; then
    while IFS= read -r line; do
      command_args+=("$line")
    done <"$(command_file "$name")"
  fi
  guest_env=()
  if [ -f "$(env_file "$name")" ]; then
    while IFS= read -r line; do
      guest_env+=("$line")
    done <"$(env_file "$name")"
  fi
  if [ "${#guest_env[@]}" -eq 0 ]; then
    guest_env=("AGENT_VM_NAME=$name" "AGENT_HOST_GATEWAY=$(host_ip "$idx")")
  fi
  detach="$start_detach"
  if [ "$detach" = "1" ]; then
    trap - EXIT
  fi
  run_vm "$name"
}

stop_sandbox() {
  local name="$1" pid
  load_state "$name" || return 1
  if [ -f "$(pid_file "$name")" ]; then
    pid="$(cat "$(pid_file "$name")")"
    kill -TERM "$pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
      kill -0 "$pid" >/dev/null 2>&1 || break
      sleep 0.1
    done
    kill -KILL "$pid" >/dev/null 2>&1 || true
    rm -f "$(pid_file "$name")"
  fi
  pkill -TERM -f "krunvm start .*${name//./\\.}" >/dev/null 2>&1 || true
  cleanup_run "$name"
}

# --- argument parsing -------------------------------------------------------

subcommand="${1:-run}"
start_detach=0
case "$subcommand" in
  list | ls)
    require_root
    shift || true
    found=0
    for f in "$state_root"/state/*.conf; do
      [ -e "$f" ] || continue
      unset name idx image status online lan workspace ephemeral cpus mem
      # shellcheck disable=SC1090
      . "$f"
      found=1
      printf '%-24s %-9s %-7s %s vCPU %s MiB\n' \
        "$name" "$status" "$([ "${online:-0}" = 1 ] && printf online || printf offline)" \
        "$cpus" "$mem"
      printf '  image:     %s\n' "$image"
      printf '  workspace: %s\n' "$workspace"
      if [ -f "$(ports_file "$name")" ]; then
        while IFS=$'\t' read -r addr hport gport iport; do
          [ -n "${addr:-}" ] || continue
          printf '  publish:   %s:%s -> guest %s\n' "$addr" "$hport" "$gport"
        done <"$(ports_file "$name")"
      fi
      if [ -f "$(shares_file "$name")" ]; then
        while IFS=$'\t' read -r sname spath sro sguest; do
          [ -n "${sname:-}" ] || continue
          printf '  share:     %s:%s%s -> %s\n' "$sname" "$spath" \
            "$([ "$sro" = 1 ] && printf ' (ro)')" "$sguest"
        done <"$(shares_file "$name")"
      fi
    done
    [ "$found" = "1" ] || printf 'agent-vm: no sandboxes\n'
    exit 0
    ;;
  logs)
    require_root
    name="${2:?usage: sudo agent-vm logs NAME}"
    exec tail -n 200 -f "$(log_file "$name")"
    ;;
  stop)
    require_root
    name="${2:?usage: sudo agent-vm stop NAME}"
    stop_sandbox "$name" || die "no such sandbox: $name"
    printf 'agent-vm: stopped %s\n' "$name"
    exit 0
    ;;
  rm | remove | delete)
    require_root
    name="${2:?usage: sudo agent-vm rm NAME}"
    if load_state "$name"; then
      [ "$status" = "running" ] && stop_sandbox "$name"
      teardown_netns "$name" "$idx"
      cleanup_shares "$name" || true
      unmark_workspace "$workspace" 2>/dev/null || true
      rm -f "$(pid_file "$name")"
      krunvm delete "$name" >/dev/null 2>&1 || true
      rm -f "$(state_file "$name")" "$(ports_file "$name")" "$(shares_file "$name")" "$(command_file "$name")" "$(env_file "$name")"
    else
      krunvm delete "$name" >/dev/null 2>&1 || true
    fi
    nft_rebuild
    printf 'agent-vm: removed %s\n' "$name"
    exit 0
    ;;
  gc)
    require_root
    for f in "$state_root"/state/*.conf; do
      [ -e "$f" ] || continue
      unset name idx status workspace
      # shellcheck disable=SC1090
      . "$f"
      if ! krunvm list 2>/dev/null | grep -qx -- "$name"; then
        teardown_netns "$name" "$idx"
        unmark_workspace "${workspace:-}" 2>/dev/null || true
        rm -f "$(state_file "$name")" "$(ports_file "$name")" "$(shares_file "$name")" "$(command_file "$name")" "$(env_file "$name")" "$(pid_file "$name")"
        printf 'agent-vm: pruned %s\n' "$name"
        continue
      fi
      if [ "$status" = "running" ]; then
        if [ ! -f "$(pid_file "$name")" ]; then
          cleanup_run "$name"
        else
          pid="$(cat "$(pid_file "$name")")"
          if ! kill -0 "$pid" >/dev/null 2>&1 \
            || ! ip netns list 2>/dev/null | awk '{print $1}' | grep -qx -- "$(netns_name "$name")"; then
            cleanup_run "$name"
          fi
        fi
      fi
    done
    for ns in $(ip netns list 2>/dev/null | awk '{print $1}'); do
      case "$ns" in
        sbx-*)
          if [ ! -f "$(state_file "${ns#sbx-}")" ]; then
            ip netns del "$ns" >/dev/null 2>&1 || true
          fi
          ;;
      esac
    done
    nft_rebuild
    exit 0
    ;;
  run | up)
    if [ "$#" -gt 0 ]; then shift; fi
    ;;
  start)
    case "${2:-}" in
      -h | --help)
        usage
        exit 0
        ;;
      --detach)
        start_detach=1
        shift
        ;;
    esac
    if [ "${2:-}" = "" ]; then
      if [ "$start_detach" = "1" ]; then
        die "usage: sudo agent-vm start [--detach] NAME"
      fi
      if [ "$#" -gt 0 ]; then shift; fi
    else
      require_root
      subcommand="__start_existing"
      shift
    fi
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

if [ "${subcommand:-}" = "__start_existing" ]; then
  start_existing "${1:?usage: sudo agent-vm start NAME}"
  exit 0
fi
require_root

name=""
workspace=""
cpus="$default_cpus"
mem="$default_mem"
image="$default_image"
dns="$default_dns"
online=0
lan=0
detach=0
ephemeral=0
docker=0
ports=()
publishes=()
envs=()
shares=()
command_args=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -w | --workspace)
      workspace="${2:?-w needs a directory}"
      shift 2
      ;;
    --name)
      name="${2:?--name needs a value}"
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
    --dns)
      dns="${2:?--dns needs a value}"
      shift 2
      ;;
    --share)
      shares+=("${2:?--share needs a value}")
      shift 2
      ;;
    --port)
      ports+=("${2:?--port needs H:G}")
      shift 2
      ;;
    --publish)
      publishes+=("${2:?--publish needs ADDR:H:G}")
      shift 2
      ;;
    --env)
      envs+=("${2:?--env needs K=V}")
      shift 2
      ;;
    --online)
      online=1
      shift
      ;;
    --lan)
      lan=1
      shift
      ;;
    --offline)
      online=0
      lan=0
      shift
      ;;
    --detach)
      detach=1
      shift
      ;;
    --ephemeral)
      ephemeral=1
      shift
      ;;
    --docker)
      docker=1
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
[ "$lan" = "1" ] && [ "$online" = "0" ] && die "--lan needs --online"
ipv4_available "$dns" || die "--dns must be an IPv4 address"

[ -n "$workspace" ] || workspace="$PWD"
[ -d "$workspace" ] || die "workspace is not a directory: $workspace"
workspace="$(realpath "$workspace")"
case "$workspace" in
  *:* | *$'\n'* | *$'\t'*) die "workspace path cannot contain ':', newlines or tabs" ;;
esac
is_sensitive "$workspace" && die "refusing to expose $workspace to a guest"

if [ -z "$name" ]; then
  base="$(basename "$workspace")"
  base="$(printf '%s' "$base" | tr -c 'A-Za-z0-9_.-' '-')"
  name="agent-${base:-workspace}"
fi
valid_name "$name" || die "invalid name: $name"

if [ -f "$(state_file "$name")" ] || krunvm list 2>/dev/null | grep -qx -- "$name"; then
  die "microVM '$name' already exists; remove it with: sudo agent-vm rm $name"
fi

# Validate shares and assign guest paths.
shares_meta=()
seen_shares=" "
for spec in "${shares[@]}"; do
  sro=0
  case "$spec" in
    *:ro) sro=1; spec="${spec%:ro}" ;;
    *:rw) spec="${spec%:rw}" ;;
  esac
  case "$spec" in
    *=*) sname="${spec%%=*}"; spath="${spec#*=}" ;;
    *) spath="$spec"; sname="$(basename "$spec")" ;;
  esac
  [ -n "$sname" ] && [ -n "$spath" ] || die "--share needs [NAME=]PATH[:ro]"
  valid_name "$sname" || die "invalid share name: $sname"
  case "$seen_shares" in
    *" $sname "*) die "duplicate share name: $sname" ;;
  esac
  seen_shares+="$sname "
  [ -d "$spath" ] || die "share is not a directory: $spath"
  spath="$(realpath "$spath")"
  case "$spath" in
    *:* | *$'\n'* | *$'\t'*) die "share path cannot contain ':', newlines or tabs" ;;
  esac
  is_sensitive "$spath" && die "refusing to expose $spath to a guest"
  sguest="/share-$sname"
  shares_meta+=("$sname"$'\t'"$spath"$'\t'"$sro"$'\t'"$sguest")
done

# Primary workspace must be exclusive; --share is the deliberate exception.
if conflict="$(workspace_conflict "$name" "$workspace")"; then
  die "workspace $workspace is already used by sandbox $conflict; use --share to share it deliberately"
fi

# Validate ports before touching the network.
port_meta=()
seen_ports=" "
seen_guests=" "
slot=0
for mapping in "${ports[@]}"; do
  hport="${mapping%%:*}"
  gport="${mapping##*:}"
  [ "$hport" != "$mapping" ] || die "--port needs HOST:GUEST, got $mapping"
  check_number "$hport" "--port host" 1024 65535
  check_number "$gport" "--port guest" 1 65535
  case "$seen_ports" in
    *" $hport "*) die "host port $hport is listed twice" ;;
  esac
  case "$seen_guests" in
    *" $gport "*) die "guest port $gport is mapped twice" ;;
  esac
  seen_ports+="$hport "
  seen_guests+="$gport "
  port_meta+=("127.0.0.1"$'\t'"$hport"$'\t'"$gport"$'\t'"$slot")
  slot=$((slot + 1))
done
for mapping in "${publishes[@]}"; do
  # ADDR:H:G
  addr="${mapping%%:*}"
  rest="${mapping#*:}"
  hport="${rest%%:*}"
  gport="${rest##*:}"
  [ "$rest" != "$mapping" ] && [ "$hport" != "$rest" ] \
    || die "--publish needs ADDR:HOST:GUEST, got $mapping"
  ipv4_available "$addr" || die "--publish address must be IPv4: $addr"
  check_number "$hport" "--publish host" 1024 65535
  check_number "$gport" "--publish guest" 1 65535
  case "$seen_ports" in
    *" $hport "*) die "host port $hport is listed twice" ;;
  esac
  case "$seen_guests" in
    *" $gport "*) die "guest port $gport is mapped twice" ;;
  esac
  seen_ports+="$hport "
  seen_guests+="$gport "
  port_meta+=("$addr"$'\t'"$hport"$'\t'"$gport"$'\t'"$slot")
  slot=$((slot + 1))
done

for meta in "${port_meta[@]}"; do
  IFS=$'\t' read -r addr hport gport pslot <<<"$meta"
  host_port_in_use "$hport" && die "host port $hport is already in use"
  published_port_in_use "$hport" && die "port $hport is already published by another sandbox"
done

case "$image" in
  '' | *[!A-Za-z0-9_.:/@+-]*) die "invalid image reference: $image" ;;
  -*) die "invalid image reference: $image" ;;
esac

guest_env=()
for entry in "${envs[@]}"; do
  case "$entry" in
    *=*) guest_env+=("$entry") ;;
    *) die "--env needs K=V, got $entry" ;;
  esac
  case "$entry" in
    *$'\n'* | *$'\t'*) die "--env values cannot contain newlines or tabs" ;;
  esac
done

# libkrun serializes the command into the guest kernel command line, which
# cannot carry newlines or tabs.  Fail clearly instead of letting libkrun
# panic with "InvalidAscii".
for arg in "${command_args[@]}"; do
  case "$arg" in
    *$'\n'* | *$'\t'*)
      die "command arguments cannot contain newlines or tabs; use a script in the workspace"
      ;;
  esac
done

idx="$(alloc_idx)"
guest_env+=("AGENT_VM_NAME=$name" "AGENT_HOST_GATEWAY=$(host_ip "$idx")")
status="starting"
save_state "$name"
if [ "${#command_args[@]}" -gt 0 ]; then
  printf '%s\n' "${command_args[@]}" >"$(command_file "$name")"
else
  rm -f "$(command_file "$name")"
fi
if [ "${#guest_env[@]}" -gt 0 ]; then
  printf '%s\n' "${guest_env[@]}" >"$(env_file "$name")"
fi
printf '%s\n' "${shares_meta[@]}" >"$(shares_file "$name")"

# Fill in the internal TSI port for every mapping.  The port lives inside the
# network namespace only; socat relays it to the veth address.
: >"$(ports_file "$name")"
used_internal=" "
for meta in "${port_meta[@]}"; do
  IFS=$'\t' read -r addr hport gport pslot <<<"$meta"
  iport=$((internal_base + (idx - 1) * 64 + pslot))
  while :; do
    case "$seen_ports" in
      *" $iport "*) iport=$((iport + 1)); continue ;;
    esac
    case "$used_internal" in
      *" $iport "*) iport=$((iport + 1)); continue ;;
    esac
    break
  done
  used_internal+="$iport "
  check_number "$iport" "internal port" 1024 65535
  printf '%s\t%s\t%s\t%s\n' "$addr" "$hport" "$gport" "$iport" >>"$(ports_file "$name")"
done

setup_netns "$name" "$idx" "$online"
prepare_shares "$name"
mark_workspace "$name" "$workspace"
trap 'cleanup_run "$name"' EXIT

printf 'agent-vm: %s\n' "$name"
printf '  image:     %s\n' "$image"
printf '  workspace: %s -> /workspace\n' "$workspace"
printf '  resources: %s vCPU, %s MiB\n' "$cpus" "$mem"
printf '  network:   %s\n' "$([ "$online" = "1" ] && printf 'online' || printf 'offline')"
for meta in "${shares_meta[@]}"; do
  IFS=$'\t' read -r sname spath sro sguest <<<"$meta"
  printf '  share:     %s -> %s%s\n' "$spath" "$sguest" "$([ "$sro" = 1 ] && printf ' (ro)')"
done
for meta in "${port_meta[@]}"; do
  IFS=$'\t' read -r addr hport gport pslot <<<"$meta"
  printf '  publish:   %s:%s -> guest %s\n' "$addr" "$hport" "$gport"
done

volume_args=("--volume" "$workspace:/workspace")
if [ "$docker" = "1" ]; then
  write_docker_init
  volume_args+=("--volume" "$run_root/ro/docker-init:/agent-docker-init")
fi
n=0
for meta in "${shares_meta[@]}"; do
  IFS=$'\t' read -r sname spath sro sguest <<<"$meta"
  src="$(volume_source "$name" "$sname" "$spath" "$sro" "$n")"
  volume_args+=("--volume" "$src:$sguest")
  n=$((n + 1))
done

create_args=(
  --name "$name"
  --cpus "$cpus"
  --mem "$mem"
  --dns "$dns"
  --workdir /workspace
)
for v in "${volume_args[@]}"; do create_args+=("$v"); done
while IFS=$'\t' read -r addr hport gport iport; do
  [ -n "${addr:-}" ] || continue
  # krunvm remaps the guest's listen port to the internal host port; TSI then
  # binds it inside the network namespace.
  create_args+=(--port "$iport:$gport")
done <"$(ports_file "$name")"

if ! krunvm create "${create_args[@]}" "$image"; then
  cleanup_run "$name"
  die "krunvm create failed"
fi

if [ "$detach" = "1" ]; then
  trap - EXIT
fi
run_vm "$name"
