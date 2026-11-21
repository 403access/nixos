#!/usr/bin/env bash
# Optional real-hive smoke test for the offline registry library.
#
# This reads copies of actual SYSTEM/SOFTWARE hives and applies the same merge
# operations as apply.sh.  The source hives are never modified.
#
# Usage:
#   OFFLINE_TEST_HIVE_DIR=/path/to/hive-dir ./offline-hive-smoke.sh
#
# The directory must contain SYSTEM and SOFTWARE.  If hivexregedit or the
# directory is missing, the script exits 0 with SKIP so it is safe in CI.

set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$here/../../.." && pwd)"
# shellcheck source=../offline/registry.sh
source "$repo_root/scripts/windows/offline/registry.sh"

if ! command -v "${HIVEXREGEDIT:-hivexregedit}" >/dev/null 2>&1; then
    echo "SKIP: hivexregedit not installed"
    exit 0
fi

if [ -z "${OFFLINE_TEST_HIVE_DIR:-}" ]; then
    echo "SKIP: set OFFLINE_TEST_HIVE_DIR to a directory containing SYSTEM and SOFTWARE"
    exit 0
fi

src_sys="$OFFLINE_TEST_HIVE_DIR/SYSTEM"
src_soft="$OFFLINE_TEST_HIVE_DIR/SOFTWARE"
if [ ! -f "$src_sys" ] || [ ! -f "$src_soft" ]; then
    echo "SKIP: $OFFLINE_TEST_HIVE_DIR must contain SYSTEM and SOFTWARE"
    exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/winslim-hive-smoke.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/hives" "$tmp/win"
cp -a "$src_sys" "$tmp/hives/SYSTEM"
cp -a "$src_soft" "$tmp/hives/SOFTWARE"

# Minimal Windows tree so the rename steps have something to act on.
for root in \
    "$tmp/win/Program Files/Windows Defender" \
    "$tmp/win/ProgramData/Microsoft/Windows Defender/Platform/1.0" \
    "$tmp/win/Windows/SystemApps/MicrosoftWindows.Client.CBS_cw5n1h2txyewy" \
    "$tmp/win/Windows/System32/Tasks/Microsoft/Windows/Windows Defender"; do
    mkdir -p "$root"
done
for name in MsMpEng.exe MpDefenderCoreService.exe NisSrv.exe MpCmdRun.exe; do
    : > "$tmp/win/Program Files/Windows Defender/$name"
    : > "$tmp/win/ProgramData/Microsoft/Windows Defender/Platform/1.0/$name"
done
for name in SearchHost.exe FESearchHost.exe; do
    : > "$tmp/win/Windows/SystemApps/MicrosoftWindows.Client.CBS_cw5n1h2txyewy/$name"
done

echo "== real-hive Defender patch =="
offline_patch_defender "$tmp/hives/SYSTEM" "$tmp/hives/SOFTWARE" "$tmp/win"
offline_verify_defender "$tmp/hives/SYSTEM" "$tmp/hives/SOFTWARE" "$tmp/win"

echo "== real-hive Search patch =="
offline_patch_search "$tmp/hives/SYSTEM" "$tmp/win"
offline_verify_search "$tmp/hives/SYSTEM" "$tmp/win"

echo "== idempotency =="
offline_patch_defender "$tmp/hives/SYSTEM" "$tmp/hives/SOFTWARE" "$tmp/win" >/dev/null
offline_verify_defender "$tmp/hives/SYSTEM" "$tmp/hives/SOFTWARE" "$tmp/win"

echo "Real-hive smoke: OK"