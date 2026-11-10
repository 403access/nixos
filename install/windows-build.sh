#!/usr/bin/env bash
#
# Run the native Windows 11 slim-image build with writable output directories.
#
# Installed by install/default.nix when myInstall.windows.toolchain is
# "native" or "both".  The toolkit lives in /etc/nixos/windows (read-only for
# normal users), so this wrapper keeps the work and output directories under
# the user's home.
set -euo pipefail

repo="${WINDOWS_REPO:-/etc/nixos/windows}"
script="$repo/build-win11.sh"

if [ ! -x "$script" ]; then
  printf 'windows-build: %s is missing or not executable\n' "$script" >&2
  printf 'Set WINDOWS_REPO to the windows/ directory of a repository checkout.\n' >&2
  exit 1
fi

data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/windows-image"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/windows-image"
mkdir -p "$data_dir/out" "$cache_dir/work"

has_out=0
has_work=0
for arg in "$@"; do
  case "$arg" in
    -o | --out | --out=*)
      has_out=1
      ;;
    -w | --workdir | --workdir=*)
      has_work=1
      ;;
  esac
done

args=("$@")
if [ "$has_out" -eq 0 ]; then
  args+=(--out "$data_dir/out/Win11-$(date +%Y%m%d-%H%M).iso")
fi
if [ "$has_work" -eq 0 ]; then
  args+=(--workdir "$cache_dir/work")
fi

exec "$script" "${args[@]}"
