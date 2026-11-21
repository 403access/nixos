#!/usr/bin/env bash
# Run every test that can run on this host.
#
#   ./scripts/windows/tests/run-tests.sh
#
# Pester tests need pwsh.  The real-hive smoke test only runs when
# OFFLINE_TEST_HIVE_DIR points at a directory containing SYSTEM and SOFTWARE.

set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
failed=0

echo "== Offline registry tests =="
if ! bash "$here/offline-registry.Tests.sh"; then
    failed=1
fi

if command -v pwsh >/dev/null 2>&1; then
    echo
    echo "== PowerShell/Pester tests =="
    if ! pwsh -NoProfile -File "$here/run-tests.ps1"; then
        failed=1
    fi
else
    echo "SKIP: pwsh not installed; Pester tests not run"
fi

if [ -n "${OFFLINE_TEST_HIVE_DIR:-}" ]; then
    echo
    echo "== Real-hive smoke test =="
    if ! bash "$here/offline-hive-smoke.sh"; then
        failed=1
    fi
else
    echo "SKIP: set OFFLINE_TEST_HIVE_DIR to run the real-hive smoke test"
fi

if [ "$failed" -ne 0 ]; then
    echo
    echo "Some tests failed." >&2
    exit 1
fi

echo
echo "All tests passed."