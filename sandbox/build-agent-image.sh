#!/usr/bin/env bash
#
# build-agent-image.sh - build the Docker-capable agent image for agent-vm.
#
# Run as root: krunvm builds its microVMs with root's buildah, so an image
# built rootless is invisible to it.  The resulting image stays in
# /var/lib/containers and is reused by `agent-vm --docker`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="${1:-localhost/nixos-agent:latest}"

[ "$(id -u)" -eq 0 ] || {
  printf 'run with sudo so krunvm (root) can see the image: sudo %s\n' "$0" >&2
  exit 1
}

command -v buildah >/dev/null 2>&1 || {
  printf 'buildah is not installed; enable mySandbox first\n' >&2
  exit 1
}

exec buildah build --tag "$image" --file "$here/agent-base/Containerfile" "$here/agent-base"
