#!/usr/bin/env bash
#
# sandbox-smoke-test.sh - verify the agent microVM and Docker service sandboxes.
#
# Usage: sudo ./scripts/sandbox-smoke-test.sh
#
# Read-only for the host except for temporary workspace/project directories,
# which are removed on exit.  Images are pulled if missing.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { printf 'run with sudo: sudo %s\n' "$0" >&2; exit 1; }

user="${SUDO_USER:-nixos}"
suffix="smoke-$$"
work="/var/lib/agent-workspaces/$suffix"
project="/var/lib/projects/$suffix"
port=18080

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

cleanup() {
  project-down "$suffix" >/dev/null 2>&1 || true
  rm -rf -- "$project" "$work"
}
trap cleanup EXIT

command -v agent-vm >/dev/null 2>&1 || fail "agent-vm is not installed"
command -v project-up >/dev/null 2>&1 || fail "project-up is not installed"
command -v docker >/dev/null 2>&1 || fail "docker is not installed"

printf '\n== agent microVM ==\n'
mkdir -p "$work"
printf 'hello smoke\n' >"$work/hello.txt"

agent_out="$(agent-vm --workspace "$work" \
  --image docker.io/library/alpine:latest --ephemeral -- \
  sh -c 'cat /workspace/hello.txt; (wget -q -T2 -O- http://example.com >/dev/null 2>&1 && echo NET=up || echo NET=down)')"

printf '%s\n' "$agent_out"
grep -q 'hello smoke' <<<"$agent_out" || fail "workspace file was not visible in the microVM"
grep -q 'NET=down' <<<"$agent_out" || fail "microVM had network access; it must be offline"
pass "workspace visible, guest offline"

printf '\n== docker service ==\n'
cp -r /etc/nixos/services/templates/example "$project"
sed -i '/^name: example$/d' "$project/compose.yaml"
sed -i "s/127.0.0.1:8080/127.0.0.1:$port/" "$project/compose.yaml"

project-up "$suffix" >/dev/null

ready=0
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.5
done
[ "$ready" -eq 1 ] || fail "service did not answer on 127.0.0.1:$port"
pass "published on 127.0.0.1:$port"

container="$suffix-whoami-1"
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

printf '\nAll sandbox checks passed.\n'