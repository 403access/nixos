#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOKEN_FILE="${TMPDIR:-/tmp}/nixos-control-local-token"

if [ ! -s "$TOKEN_FILE" ]; then
  (umask 077; openssl rand -hex 32 > "$TOKEN_FILE")
fi

cd "$ROOT/server"
cargo run -- \
  --listen 127.0.0.1:8787 \
  --token-file "$TOKEN_FILE" \
  --allow-rebuild=false \
  --allow-power=false &
SERVER_PID=$!

cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cd "$ROOT/peripherals-ui"
echo "Local API:  http://127.0.0.1:8787"
echo "Token file: $TOKEN_FILE"
echo "In Settings, use http://127.0.0.1:8787 and the token above."
API_TARGET=http://127.0.0.1:8787 bun run dev