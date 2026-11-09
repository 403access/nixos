#!/usr/bin/env bash
#
# Run the requested command as root (wimlib needs root to apply security
# descriptors) and hand the generated files back to the invoking host user.
# On Docker Desktop/OrbStack for macOS the bind mount already maps ownership,
# so the chown is best-effort there.
set -Eeuo pipefail

if [[ "$#" -eq 0 ]]; then
    set -- bash
fi

status=0
"$@" || status=$?

if [[ -n "${HOST_UID:-}" && -n "${HOST_GID:-}" ]]; then
    for path in /repo/windows/out /repo/windows/work /output /work; do
        if [[ -e "$path" ]]; then
            chown -R "$HOST_UID:$HOST_GID" "$path" 2>/dev/null || true
        fi
    done
fi

exit "$status"
