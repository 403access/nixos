#!/usr/bin/env bash
# Lifecycle helper for the OrbStack NixOS test machine (see ./README.md).
#
#   ./vm/vm.sh up        create/start the machine and apply the configuration
#   ./vm/vm.sh desktop   switch the VM desktop profile (xfce/rice/plasma)
#   ./vm/vm.sh status    machine, services, token, API health, URLs
#   ./vm/vm.sh shell     shell inside the machine (root for `root`)
#   ./vm/vm.sh token     print the API token
#   ./vm/vm.sh ios       build/install/launch the app against the machine
#   ./vm/vm.sh vnc       open the VNC desktop
#   ./vm/vm.sh stop      pause the machine (keeps its disk)
#   ./vm/vm.sh start     resume a paused machine
#   ./vm/vm.sh delete    destroy the machine (OrbStack asks for confirmation)
#
# Environment:
#   ORB_MACHINE   machine name (default: control-test)
#   SIM_NAME      simulator to boot when none is running (default: iPhone 17)
set -euo pipefail

MACHINE="${ORB_MACHINE:-control-test}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="${MACHINE}.orb.local"
API_PORT=8787
VNC_PORT=5901

exists() { orb list -q | grep -qx "$MACHINE"; }
running() { orb list -r -q | grep -qx "$MACHINE"; }

# The guest address. OrbStack's <machine>.orb.local DNS record can be stale
# after stop/start, so fall back to this wherever it matters.
machine_ip() {
  orb list | awk -v m="$MACHINE" '$1 == m { print $NF }'
}

reachable() { # host port
  nc -z -G 2 -w 2 "$1" "$2" >/dev/null 2>&1
}

api_host() {
  if reachable "$NAME" "$API_PORT"; then
    echo "$NAME"
  else
    machine_ip
  fi
}

require_machine() {
  if ! exists; then
    echo "Machine '$MACHINE' does not exist. Run: ./vm/vm.sh up" >&2
    exit 1
  fi
}

require_running() {
  require_machine
  if ! running; then
    echo "Machine '$MACHINE' is stopped. Run: ./vm/vm.sh start" >&2
    exit 1
  fi
}

token() {
  orb -m "$MACHINE" sudo cat /var/lib/nixos-control/token
}

create() {
  if exists; then
    echo "Machine '$MACHINE' already exists."
  else
    echo "Creating NixOS machine '$MACHINE'..."
    orb create --cpus 4 --memory 6G --disk 40G nixos:25.11 "$MACHINE"
  fi
}

up() {
  create
  running || orb start "$MACHINE"
  "$ROOT/vm/apply.sh"
}

desktop() {
  local profile="${1:-}"
  if [[ -z "$profile" ]]; then
    echo "Usage: ./vm/vm.sh desktop <xfce|rice|plasma>" >&2
    echo "Hyprland is Wayland-only and cannot be shown over this VM's X11 VNC display." >&2
    exit 1
  fi
  create
  running || orb start "$MACHINE"
  DESKTOP_PROFILE="$profile" "$ROOT/vm/apply.sh"
}

start() {
  require_machine
  if running; then
    echo "Machine '$MACHINE' is already running."
  else
    orb start "$MACHINE"
  fi
}

stop() {
  require_machine
  if running; then
    orb stop "$MACHINE"
  else
    echo "Machine '$MACHINE' is already stopped."
  fi
}

destroy() {
  require_machine
  orb delete "$MACHINE"
}

status() {
  if ! exists; then
    echo "Machine '$MACHINE' does not exist. Run: ./vm/vm.sh up"
    return 1
  fi

  if ! running; then
    echo "Machine:  $MACHINE (stopped)"
    return 0
  fi

  local ip tok host code profile
  ip=$(machine_ip)
  tok=$(token)
  host=$(api_host)
  profile=$(orb -m "$MACHINE" sed -nE 's/.*myDesktop\.profile = "(.*)".*/\1/p' \
    /etc/nixos/vm/desktop.nix 2>/dev/null | head -1)

  echo "Machine:  $MACHINE (running, $ip)"
  echo "Desktop:  ${profile:-unknown} profile — vnc://$host:$VNC_PORT"
  echo "API:      http://$host:$API_PORT"
  echo "Token:    ${tok:0:8}… (./vm/vm.sh token for the full value)"
  if [[ "$host" != "$NAME" ]]; then
    echo "Note:     $NAME did not answer; using the machine IP instead."
  fi
  echo

  for unit in nixos-control vnc-server vnc-session; do
    state=$(orb -m "$MACHINE" systemctl is-active "$unit" 2>/dev/null || true)
    printf '%-14s %s\n' "$unit" "${state:-unknown}"
  done

  code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 \
    -H "Authorization: Bearer $tok" "http://$host:$API_PORT/api/health" || true)
  echo
  echo "Health:   HTTP ${code:-unreachable}"
}

shell() {
  require_running
  exec orb -m "$MACHINE" -s
}

root_shell() {
  require_running
  exec orb -m "$MACHINE" -u root -s
}

open_vnc() {
  require_running
  local host
  host=$(api_host)
  echo "Opening vnc://$host:$VNC_PORT (password is set in vm/configuration.nix)"
  open "vnc://$host:$VNC_PORT"
}

logs() {
  require_running
  exec orb -m "$MACHINE" sudo journalctl -u nixos-control -f
}

simulator_udid() {
  xcrun simctl list devices booted \
    | sed -nE 's/^[[:space:]]+(iPhone[^()]*) \(([0-9A-Fa-f-]{36})\) \(Booted\).*/\2/p' \
    | head -1
}

ios() {
  require_running
  local tab="${1:-dashboard}" udid sim host
  host=$(api_host)

  udid=$(simulator_udid)
  if [[ -z "$udid" ]]; then
    sim="${SIM_NAME:-iPhone 17}"
    echo "Booting simulator '$sim'..."
    xcrun simctl boot "$sim" >/dev/null 2>&1 || true
    udid=$(simulator_udid)
  fi
  if [[ -z "$udid" ]]; then
    echo "No booted iPhone simulator found. Set SIM_NAME, e.g. SIM_NAME='iPhone 17' ./vm/vm.sh ios" >&2
    exit 1
  fi

  echo "Building..."
  (
    cd "$ROOT/ios"
    xcodegen generate >/dev/null
    xcodebuild -project NixOSControl.xcodeproj -scheme NixOSControl \
      -sdk iphonesimulator -destination "id=$udid" \
      -derivedDataPath build CODE_SIGNING_ALLOWED=NO -quiet build
  )

  app="$ROOT/ios/build/Build/Products/Debug-iphonesimulator/NixOSControl.app"
  bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")

  xcrun simctl install "$udid" "$app"
  echo "Launching $bundle against http://$host:$API_PORT (tab: $tab)..."
  SIMCTL_CHILD_NIXOS_CONTROL_SERVER="http://$host:$API_PORT" \
  SIMCTL_CHILD_NIXOS_CONTROL_TOKEN="$(token)" \
  SIMCTL_CHILD_NIXOS_CONTROL_TAB="$tab" \
  xcrun simctl launch --terminate-running-process "$udid" "$bundle"
}

usage() {
  cat <<'EOF'
Usage: ./vm/vm.sh <command>

  up        create/start the machine and apply the configuration
  desktop   switch the desktop profile (xfce|rice|plasma)
  status    machine, services, token, API health, URLs
  ip        print the machine's IP address
  shell     shell inside the machine (`root` for a root shell)
  token     print the API token
  ios       build/install/launch the app (optional tab name, default dashboard)
  vnc       open the VNC desktop
  logs      follow the nixos-control journal
  create    create the machine without rebuilding
  start     resume a paused machine
  stop      pause the machine (keeps its disk)
  delete    destroy the machine (OrbStack asks for confirmation)

Environment: ORB_MACHINE (default control-test), SIM_NAME (default iPhone 17)
EOF
}

case "${1:-}" in
  up|apply) up ;;
  desktop) desktop "${2:-}" ;;
  create) create ;;
  start) start ;;
  stop) stop ;;
  delete|destroy) destroy ;;
  status) status ;;
  ip) require_running; machine_ip ;;
  shell) shell ;;
  root) root_shell ;;
  token) require_running; token ;;
  vnc) open_vnc ;;
  ios) ios "${2:-}" ;;
  logs) logs ;;
  ""|-h|--help|help) usage ;;
  *) echo "Unknown command: $1" >&2; usage >&2; exit 1 ;;
esac
