#!/usr/bin/env bash
# Download the Windows app installers pinned in apps.json.
# Usage: ./fetch-apps.sh
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
apps="$here/apps"
mkdir -p "$apps"

python3 - "$here/apps.json" "$apps" <<'PY'
import hashlib
import json
import os
import shutil
import sys
import urllib.request

manifest_path, destination = sys.argv[1], sys.argv[2]
with open(manifest_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
apps = data["apps"] if isinstance(data, dict) else data

failures = 0

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

for app in apps:
    target = os.path.join(destination, app["file"])
    expected = (app.get("sha256") or "").lower()

    if os.path.exists(target):
        actual = sha256(target)
        if not expected or actual == expected:
            print(f"ok      {app['file']}")
            continue
        print(f"stale   {app['file']} (hash mismatch, downloading)")
        os.remove(target)

    partial = target + ".part"
    print(f"fetch   {app['file']}")
    request = urllib.request.Request(
        app["url"],
        headers={"User-Agent": "nixos-windows-helper/1.0"},
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response, open(partial, "wb") as handle:
            shutil.copyfileobj(response, handle)
        actual = sha256(partial)
        if expected and actual != expected:
            os.remove(partial)
            print(f"BADHASH {app['file']}: expected {expected}, got {actual}", file=sys.stderr)
            failures += 1
            continue
        os.replace(partial, target)
        print(f"ok      {app['file']}  {actual}")
    except Exception as exc:
        if os.path.exists(partial):
            os.remove(partial)
        print(f"FAILED  {app['file']}: {exc}", file=sys.stderr)
        failures += 1

raise SystemExit(1 if failures else 0)
PY