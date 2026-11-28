#!/usr/bin/env bash
#
# sandbox-smoke-test.sh - verify the agent microVM isolation model.
#
# Usage: sudo ./scripts/sandbox-smoke-test.sh
#
# Checks, in order:
#   * the workspace is visible and the offline guest has no host or internet
#   * the host reaches a published guest port
#   * an online guest reaches the internet but not the host or a peer sandbox
#   * a workspace in use and a published port in use are refused
#   * two sandboxes exchange files only through an explicit share
#   * a read-only share stays read-only
#   * Docker inside a sandbox, when the agent image has been built
#
# Read-only for the host except for temporary workspace/share directories,
# which are removed on exit.  Images are pulled if missing.  The Docker
# project-service check reads $NIXOS_CONFIG/services/templates (default
# /etc/nixos) and is skipped when that layout is absent.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { printf 'run with sudo: sudo %s\n' "$0" >&2; exit 1; }

image="${SMOKE_IMAGE:-docker.io/library/alpine:latest}"
user="${SUDO_USER:-nixos}"
nixos_config="${NIXOS_CONFIG:-/etc/nixos}"
suffix="smoke-$$"
svc="svc-$$"
project="/var/lib/projects/$svc"
work_a="/var/lib/agent-workspaces/$suffix-a"
work_b="/var/lib/agent-workspaces/$suffix-b"
share="/var/lib/agent-shares/$suffix"
name_a="smoke-$suffix-a"
name_b="smoke-$suffix-b"
name_offline="smoke-$suffix-offline"
name_share_a="smoke-$suffix-sa"
name_share_b="smoke-$suffix-sb"
name_ro="smoke-$suffix-ro"
name_docker="smoke-$suffix-docker"
name_conflict="smoke-$suffix-conflict"
name_port="smoke-$suffix-port"

free_port() {
  local port="$1"
  while ss -Htln 2>/dev/null | awk '{print $4}' | grep -Eq ":$port$"; do
    port=$((port + 1))
  done
  printf '%s\n' "$port"
}
host_port="$(free_port $((18000 + ($$ % 500))))"
pub_port="$(free_port $((host_port + 1)))"
host_listener_pid=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  printf '\n-- diagnostics --\n' >&2
  nft list table inet agent_vm >&2 2>&1 || true
  ls -l /var/lib/agent-vm/state >&2 2>&1 || true
  ip netns list >&2 2>&1 || true
  ss -Htlnp 2>/dev/null | grep -E 'socat|8080' >&2 || true
  for f in /run/agent-vm/log/*.log; do
    [ -e "$f" ] || continue
    printf '== %s\n' "$f" >&2
    tail -n 20 "$f" >&2 || true
  done
  exit 1
}
pass() { printf 'PASS: %s\n' "$*"; }

cleanup() {
  [ -n "$host_listener_pid" ] && kill "$host_listener_pid" >/dev/null 2>&1 || true
  for n in "$name_a" "$name_b" "$name_offline" "$name_share_a" "$name_share_b" "$name_ro" "$name_docker" "$name_conflict" "$name_port"; do
    agent-vm stop "$n" >/dev/null 2>&1 || true
    agent-vm rm "$n" >/dev/null 2>&1 || true
  done
  project-down "$svc" >/dev/null 2>&1 || true
  rm -rf -- "$work_a" "$work_b" "$share" "$project"
}
trap cleanup EXIT

command -v agent-vm >/dev/null 2>&1 || fail "agent-vm is not installed"
command -v socat >/dev/null 2>&1 || fail "socat is not installed"
command -v nft >/dev/null 2>&1 || fail "nftables is not installed"

mkdir -p "$work_a" "$work_b" "$share"
printf 'hello smoke\n' >"$work_a/hello.txt"
printf 'shared seed\n' >"$share/seed.txt"

printf '\n== host listener ==\n'
socat "TCP-LISTEN:$host_port,bind=0.0.0.0,reuseaddr,fork" \
  "SYSTEM:printf 'HTTP/1.0 200 OK\\r\\n\\r\\nHOST-SECRET\\n'" \
  >/dev/null 2>&1 &
host_listener_pid=$!
pass "host service on 0.0.0.0:$host_port"

printf '\n== offline microVM ==\n'
out="$(agent-vm run --name "$name_offline" --workspace "$work_a" \
  --image "$image" --offline --ephemeral \
  --env "HOSTPORT=$host_port" -- /bin/sh -c 'cat /workspace/hello.txt; wget -q -T2 -O- "http://$AGENT_HOST_GATEWAY:$HOSTPORT/" >/dev/null 2>&1 && echo HOST=up || echo HOST=down; wget -q -T2 -O- http://example.com/ >/dev/null 2>&1 && echo NET=up || echo NET=down')"
printf '%s\n' "$out"
grep -q 'hello smoke' <<<"$out" || fail "workspace file was not visible in the microVM"
grep -q 'HOST=down' <<<"$out" || fail "offline microVM reached the host"
grep -q 'NET=down' <<<"$out" || fail "offline microVM reached the internet"
pass "workspace visible, guest cold to the host and the internet"

printf '\n== published port and peer isolation ==\n'
cat >"$work_a/serve.sh" <<'SH'
while true; do
  printf 'HTTP/1.0 200 OK\r\nContent-Length: 14\r\n\r\nsandbox-index\n' | nc -l -p 8080 -s 0.0.0.0
done
SH
agent-vm run --name "$name_a" --workspace "$work_a" --image "$image" \
  --online --detach --port "$pub_port:8080" -- /bin/sh /workspace/serve.sh >/dev/null
sleep 0.5

state="/var/lib/agent-vm/state/$name_a.conf"
[ -f "$state" ] || fail "missing state for $name_a"
idx="$(sed -n 's/^idx=//p' "$state")"
[ -n "$idx" ] || fail "missing sandbox index"
peer_ip="10.213.$idx.2"
gateway="10.213.$idx.1"

ready=0
for _ in $(seq 1 40); do
  if curl -fsS "http://127.0.0.1:$pub_port/" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.25
done
[ "$ready" -eq 1 ] || fail "host could not reach 127.0.0.1:$pub_port"
body="$(curl -fsS "http://127.0.0.1:$pub_port/" 2>/dev/null || true)"
[ "$body" = "sandbox-index" ] || fail "published port returned '$body', not the guest response"
pass "host -> published guest port works"

host_lan_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"

out="$(agent-vm run --name "$name_b" --workspace "$work_b" --image "$image" \
  --online --ephemeral \
  --env "HOSTPORT=$host_port" --env "LANIP=${host_lan_ip:-127.0.0.1}" \
  --env "PEER=$peer_ip" --env "PEERPORT=$pub_port" --env "GATEWAY=$gateway" -- /bin/sh -c 'wget -q -T2 -O- "http://$GATEWAY:$HOSTPORT/" >/dev/null 2>&1 && echo GATEWAY=up || echo GATEWAY=down; wget -q -T2 -O- "http://$LANIP:$HOSTPORT/" >/dev/null 2>&1 && echo HOST=up || echo HOST=down; wget -q -T2 -O- "http://$PEER:$PEERPORT/" >/dev/null 2>&1 && echo PEER=up || echo PEER=down; wget -q -T5 -O- http://example.com/ >/dev/null 2>&1 && echo NET=up || echo NET=down')"
printf '%s\n' "$out"
grep -q 'GATEWAY=down' <<<"$out" || fail "guest reached the host through the sandbox gateway"
grep -q 'HOST=down' <<<"$out" || fail "guest reached a host service on the LAN address"
grep -q 'PEER=down' <<<"$out" || fail "sandbox A reached sandbox B"
if grep -q 'NET=down' <<<"$out"; then
  printf 'NOTE: online egress did not work; check the host uplink and NAT\n'
else
  pass "online egress works, host and peer stay unreachable"
fi

printf '\n== workspace ownership ==\n'
if agent-vm run --name "$name_conflict" --workspace "$work_a" \
  --image "$image" --ephemeral -- true >/dev/null 2>&1; then
  fail "a second sandbox was allowed to mount a workspace already in use"
fi
pass "a workspace in use is refused"

printf '\n== port ownership ==\n'
if agent-vm run --name "$name_port" --workspace "$work_b" \
  --image "$image" --ephemeral --port "$pub_port:8080" -- true >/dev/null 2>&1; then
  fail "a second sandbox was allowed to publish port $pub_port"
fi
pass "a published port cannot be claimed twice"

agent-vm stop "$name_a" >/dev/null

printf '\n== shared folder between two sandboxes ==\n'
agent-vm run --name "$name_share_a" --workspace "$work_a" --image "$image" \
  --ephemeral --share "team=$share" -- /bin/sh -c 'cat /share-team/seed.txt; echo from-sandbox-a > /share-team/a.txt' \
  | grep -q 'shared seed' || fail "sandbox A could not read the shared folder"

agent-vm run --name "$name_share_b" --workspace "$work_b" --image "$image" \
  --ephemeral --share "team=$share" -- /bin/sh -c 'cat /share-team/a.txt' \
  | grep -q 'from-sandbox-a' || fail "sandbox B could not read sandbox A's shared file"
pass "host <-> A <-> B through one explicit share"

out="$(agent-vm run --name "$name_ro" --workspace "$work_b" --image "$image" \
  --ephemeral --share "docs=$share:ro" -- /bin/sh -c 'echo nope > /share-docs/nope 2>/dev/null && echo RO=writable || echo RO=readonly')"
grep -q 'RO=readonly' <<<"$out" || fail "a read-only share was writable"
pass "read-only shares stay read-only"

if buildah images --format '{{.Name}}:{{.Tag}}' 2>/dev/null | grep -qx 'localhost/nixos-agent:latest'; then
  printf '\n== docker inside the sandbox ==\n'
  agent-vm run --name "$name_docker" --workspace "$work_b" \
    --image localhost/nixos-agent:latest --docker --ephemeral -- docker info \
    >/dev/null || fail "dockerd did not start inside the sandbox"
  pass "docker runs inside the sandbox"
else
  printf '\n== docker inside the sandbox ==\n'
  printf 'SKIP: build sandbox/agent-base first (sudo ./sandbox/build-agent-image.sh)\n'
fi

if command -v project-up >/dev/null 2>&1 \
  && command -v docker >/dev/null 2>&1 \
  && [ -d "$nixos_config/services/templates/example" ]; then
  printf '\n== docker project service ==\n'
  svc_port="$(free_port $((pub_port + 10)))"
  cp -r "$nixos_config/services/templates/example" "$project"
  sed -i '/^name: example$/d' "$project/compose.yaml"
  sed -i "s/127.0.0.1:8080/127.0.0.1:$svc_port/" "$project/compose.yaml"
  project-up "$svc" >/dev/null || fail "project-up failed for $svc"

  ready=0
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:$svc_port/" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.5
  done
  [ "$ready" -eq 1 ] || fail "service did not answer on 127.0.0.1:$svc_port"
  pass "published on 127.0.0.1:$svc_port"

  container="$svc-whoami-1"
  inspect="$(docker inspect "$container" \
    --format '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.Privileged}} {{json .HostConfig.CapDrop}}')"
  [ "$inspect" = 'true false ["ALL"]' ] \
    || fail "container hardening changed: $inspect"
  pass "read-only rootfs, no privileges, all capabilities dropped"

  if [ -n "$user" ] && [ "$user" != "root" ]; then
    if sudo -u "$user" docker ps >/dev/null 2>&1; then
      fail "user $user can reach the Docker socket; remove it from the docker group"
    fi
    pass "user $user cannot reach the Docker socket"
  fi
else
  printf '\n== docker project service ==\n'
  printf 'SKIP: project-up, docker or the services template is not installed\n'
fi

printf '\nAll sandbox checks passed.\n'
