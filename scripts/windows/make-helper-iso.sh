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

xorriso -as mkisofs -o "$out" -J -R "$stage"
printf 'wrote %s\n' "$out"
