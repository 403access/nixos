#!/usr/bin/env bash
# Build a helper CD with the Windows scripts in this directory.
# Usage: ./make-helper-iso.sh [OUTPUT.iso]
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/../.." && pwd)"
out="${1:-/tmp/windows-helper.iso}"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

cp "$here"/*.ps1 "$here"/*.bat "$stage/"
cp "$repo/windows/scripts/SetupComplete.ps1" "$stage/"
if [ -f "$here/README.md" ]; then
  cp "$here/README.md" "$stage/"
fi
if [ -f "$here/apps.json" ]; then
  cp "$here/apps.json" "$stage/"
fi
if [ -d "$here/apps" ]; then
  cp -R "$here/apps" "$stage/apps"
fi

xorriso -as mkisofs -o "$out" -J -R "$stage"
printf 'wrote %s\n' "$out"
