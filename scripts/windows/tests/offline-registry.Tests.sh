#!/usr/bin/env bash
# Regression tests for the offline hive patch.
#
# Uses fake-hivexregedit.py, so libhivex and a Windows disk are not required.
# The real hives are exercised by the optional integration script.

set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$here/../../.." && pwd)"
# shellcheck source=../offline/registry.sh
source "$repo_root/scripts/windows/offline/registry.sh"

export HIVEXREGEDIT="$here/fake-hivexregedit.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/winslim-offline-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

check_eq() {
    local expected="$1" actual="$2" message="$3"
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $message (expected '$expected', got '$actual')"
    fi
}

check_ok() {
    local message="$1"
    shift
    if "$@"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $message"
    fi
}

check_fails() {
    local message="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail=$((fail + 1))
        echo "FAIL: $message (command unexpectedly succeeded)"
    else
        pass=$((pass + 1))
    fi
}

check_file() {
    local path="$1" message="$2"
    if [ -e "$path" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $message (missing $path)"
    fi
}

check_missing() {
    local path="$1" message="$2"
    if [ ! -e "$path" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $message (still present: $path)"
    fi
}

setup_hives() {
    local current="${1:-1}"
    rm -rf "$tmp/hives"
    mkdir -p "$tmp/hives"
    : > "$tmp/hives/SYSTEM"
    : > "$tmp/hives/SOFTWARE"
    cat > "$tmp/hives/SYSTEM.json" <<JSON
{
  "HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\Select": {"Current": ${current}},
  "HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\ControlSet001\\\\Services\\\\WinDefend": {"Start": 3},
  "HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\ControlSet001\\\\Services\\\\WdNisSvc": {"Start": 3},
  "HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\ControlSet001\\\\Services\\\\WdNisDrv": {"Start": 3},
  "HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\ControlSet001\\\\Services\\\\SecurityHealthService": {"Start": 3},
  "HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\ControlSet001\\\\Services\\\\wscsvc": {"Start": 2},
  "HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\ControlSet001\\\\Services\\\\Sense": {"Start": 3},
  "HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\ControlSet001\\\\Services\\\\WSearch": {"Start": 2},
  "HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\ControlSet002\\\\Services\\\\WinDefend": {"Start": 3},
  "HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\ControlSet002\\\\Services\\\\WdNisSvc": {"Start": 3},
  "HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\ControlSet002\\\\Services\\\\WdNisDrv": {"Start": 3},
  "HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\ControlSet002\\\\Services\\\\SecurityHealthService": {"Start": 3},
  "HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\ControlSet002\\\\Services\\\\wscsvc": {"Start": 2},
  "HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\ControlSet002\\\\Services\\\\Sense": {"Start": 3},
  "HKEY_LOCAL_MACHINE\\\\SYSTEM\\\\ControlSet002\\\\Services\\\\WSearch": {"Start": 2}
}
JSON
    echo '{}' > "$tmp/hives/SOFTWARE.json"
}

setup_windows_tree() {
    rm -rf "$tmp/win"
    mkdir -p "$tmp/win/Program Files/Windows Defender"
    mkdir -p "$tmp/win/ProgramData/Microsoft/Windows Defender/Platform/1.2.3"
    mkdir -p "$tmp/win/Windows/SystemApps/MicrosoftWindows.Client.CBS_cw5n1h2txyewy"
    mkdir -p "$tmp/win/Windows/System32/Tasks/Microsoft/Windows/Windows Defender"

    for name in MsMpEng.exe MpDefenderCoreService.exe NisSrv.exe MpCmdRun.exe; do
        : > "$tmp/win/Program Files/Windows Defender/$name"
        : > "$tmp/win/ProgramData/Microsoft/Windows Defender/Platform/1.2.3/$name"
    done
    for name in SearchHost.exe FESearchHost.exe MiniSearchHost.exe SearchApp.exe; do
        : > "$tmp/win/Windows/SystemApps/MicrosoftWindows.Client.CBS_cw5n1h2txyewy/$name"
    done
    for name in 'Windows Defender Cache Maintenance' 'Windows Defender Cleanup' 'Windows Defender Scheduled Scan' 'Windows Defender Verification'; do
        : > "$tmp/win/Windows/System32/Tasks/Microsoft/Windows/Windows Defender/$name"
    done
}

echo "== control set =="
setup_hives 1
check_eq "ControlSet001" "$(hive_current_control_set "$tmp/hives/SYSTEM")" 'Current=1 maps to ControlSet001'

setup_hives 2
check_eq "ControlSet002" "$(hive_current_control_set "$tmp/hives/SYSTEM")" 'Current=2 maps to ControlSet002'

echo "== Defender patch =="
setup_hives 1
setup_windows_tree
offline_patch_defender "$tmp/hives/SYSTEM" "$tmp/hives/SOFTWARE" "$tmp/win" >/dev/null

check_eq 4 "$(hive_get_dword 'HKEY_LOCAL_MACHINE\SYSTEM' "$tmp/hives/SYSTEM" 'ControlSet001\Services\WinDefend' Start)" 'WinDefend Start=4'
check_eq 4 "$(hive_get_dword 'HKEY_LOCAL_MACHINE\SYSTEM' "$tmp/hives/SYSTEM" 'ControlSet001\Services\WdNisSvc' Start)" 'WdNisSvc Start=4'
check_eq 4 "$(hive_get_dword 'HKEY_LOCAL_MACHINE\SYSTEM' "$tmp/hives/SYSTEM" 'ControlSet001\Services\WdNisDrv' Start)" 'WdNisDrv Start=4'
check_eq 4 "$(hive_get_dword 'HKEY_LOCAL_MACHINE\SYSTEM' "$tmp/hives/SYSTEM" 'ControlSet001\Services\SecurityHealthService' Start)" 'SecurityHealthService Start=4'
check_eq 4 "$(hive_get_dword 'HKEY_LOCAL_MACHINE\SYSTEM' "$tmp/hives/SYSTEM" 'ControlSet001\Services\wscsvc' Start)" 'wscsvc Start=4'
check_eq 4 "$(hive_get_dword 'HKEY_LOCAL_MACHINE\SYSTEM' "$tmp/hives/SYSTEM" 'ControlSet001\Services\Sense' Start)" 'Sense Start=4'

check_eq 1 "$(hive_get_dword 'HKEY_LOCAL_MACHINE\SOFTWARE' "$tmp/hives/SOFTWARE" 'Policies\Microsoft\Windows Defender' DisableAntiSpyware)" 'DisableAntiSpyware=1'
check_eq 1 "$(hive_get_dword 'HKEY_LOCAL_MACHINE\SOFTWARE' "$tmp/hives/SOFTWARE" 'Policies\Microsoft\Windows Defender' DisableAntiVirus)" 'DisableAntiVirus=1'
check_eq 1 "$(hive_get_dword 'HKEY_LOCAL_MACHINE\SOFTWARE' "$tmp/hives/SOFTWARE" 'Policies\Microsoft\Windows Defender\Real-Time Protection' DisableRealtimeMonitoring)" 'DisableRealtimeMonitoring=1'
check_eq 1 "$(hive_get_dword 'HKEY_LOCAL_MACHINE\SOFTWARE' "$tmp/hives/SOFTWARE" 'Policies\Microsoft\Windows Defender\Real-Time Protection' DisableBehaviorMonitoring)" 'DisableBehaviorMonitoring=1'
check_eq 4 "$(hive_get_dword 'HKEY_LOCAL_MACHINE\SOFTWARE' "$tmp/hives/SOFTWARE" 'Microsoft\Windows Defender\Features' TamperProtection)" 'TamperProtection=4'

for name in MsMpEng.exe MpDefenderCoreService.exe NisSrv.exe MpCmdRun.exe; do
    check_ok "IFEO $name" hive_has_value 'HKEY_LOCAL_MACHINE\SOFTWARE' "$tmp/hives/SOFTWARE" "Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\$name" Debugger
done

check_missing "$tmp/win/Program Files/Windows Defender/MsMpEng.exe" 'MsMpEng.exe renamed in Program Files'
check_missing "$tmp/win/ProgramData/Microsoft/Windows Defender/Platform/1.2.3/MsMpEng.exe" 'MsMpEng.exe renamed in Platform'
check_file "$tmp/win/Program Files/Windows Defender/MsMpEng.exe.bak" 'MsMpEng.exe backup created'
check_missing "$tmp/win/Windows/System32/Tasks/Microsoft/Windows/Windows Defender/Windows Defender Cleanup" 'Defender task renamed'
check_file "$tmp/win/Windows/System32/Tasks/Microsoft/Windows/Windows Defender/Windows Defender Cleanup.bak" 'Defender task backup created'

check_ok 'Defender verification passes' offline_verify_defender "$tmp/hives/SYSTEM" "$tmp/hives/SOFTWARE" "$tmp/win"

echo "== Defender verification catches drift =="
hive_set_dword 'HKEY_LOCAL_MACHINE\SYSTEM' "$tmp/hives/SYSTEM" 'ControlSet001\Services\WinDefend' Start 3
check_fails 'WinDefend Start=3 is rejected' offline_verify_defender "$tmp/hives/SYSTEM" "$tmp/hives/SOFTWARE" "$tmp/win"
hive_set_dword 'HKEY_LOCAL_MACHINE\SYSTEM' "$tmp/hives/SYSTEM" 'ControlSet001\Services\WinDefend' Start 4

echo "== idempotency =="
offline_patch_defender "$tmp/hives/SYSTEM" "$tmp/hives/SOFTWARE" "$tmp/win" >/dev/null
check_ok 'second Defender patch is idempotent' offline_verify_defender "$tmp/hives/SYSTEM" "$tmp/hives/SOFTWARE" "$tmp/win"

echo "== Search patch =="
offline_patch_search "$tmp/hives/SYSTEM" "$tmp/win" >/dev/null
check_eq 4 "$(hive_get_dword 'HKEY_LOCAL_MACHINE\SYSTEM' "$tmp/hives/SYSTEM" 'ControlSet001\Services\WSearch' Start)" 'WSearch Start=4'
check_missing "$tmp/win/Windows/SystemApps/MicrosoftWindows.Client.CBS_cw5n1h2txyewy/SearchHost.exe" 'SearchHost.exe renamed'
check_file "$tmp/win/Windows/SystemApps/MicrosoftWindows.Client.CBS_cw5n1h2txyewy/SearchHost.exe.bak" 'SearchHost.exe backup created'
check_missing "$tmp/win/Windows/SystemApps/MicrosoftWindows.Client.CBS_cw5n1h2txyewy/FESearchHost.exe" 'FESearchHost.exe renamed'
check_ok 'Search verification passes' offline_verify_search "$tmp/hives/SYSTEM" "$tmp/win"

: > "$tmp/win/Windows/SystemApps/MicrosoftWindows.Client.CBS_cw5n1h2txyewy/SearchHost.exe"
check_fails 'restored SearchHost.exe is rejected' offline_verify_search "$tmp/hives/SYSTEM" "$tmp/win"

echo "== CurrentControlSet=002 =="
setup_hives 2
setup_windows_tree
offline_patch_defender "$tmp/hives/SYSTEM" "$tmp/hives/SOFTWARE" "$tmp/win" >/dev/null
check_eq 4 "$(hive_get_dword 'HKEY_LOCAL_MACHINE\SYSTEM' "$tmp/hives/SYSTEM" 'ControlSet002\Services\WinDefend' Start)" 'patches the active ControlSet002'
check_eq 3 "$(hive_get_dword 'HKEY_LOCAL_MACHINE\SYSTEM' "$tmp/hives/SYSTEM" 'ControlSet001\Services\WinDefend' Start)" 'leaves the inactive control set alone'

echo
echo "Offline registry tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
echo "== apply.sh hive mode =="
setup_hives 1
setup_windows_tree
if HIVEXREGEDIT="$here/fake-hivexregedit.py" bash "$repo_root/scripts/windows/offline/apply.sh" \
    --hive-dir "$tmp/hives" --windows-root "$tmp/win" --mode all --log "$tmp/apply.log" >/dev/null; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: apply.sh hive mode exited nonzero"
fi
check_eq 4 "$(hive_get_dword 'HKEY_LOCAL_MACHINE\SYSTEM' "$tmp/hives/SYSTEM" 'ControlSet001\Services\WinDefend' Start)" 'apply.sh set WinDefend Start=4'
check_eq 4 "$(hive_get_dword 'HKEY_LOCAL_MACHINE\SYSTEM' "$tmp/hives/SYSTEM" 'ControlSet001\Services\WSearch' Start)" 'apply.sh set WSearch Start=4'
check_missing "$tmp/win/Windows/SystemApps/MicrosoftWindows.Client.CBS_cw5n1h2txyewy/SearchHost.exe" 'apply.sh renamed SearchHost.exe'

if bash "$repo_root/scripts/windows/offline/apply.sh" --mode nonsense --hive-dir "$tmp/hives" >/dev/null 2>&1; then
    fail=$((fail + 1))
    echo "FAIL: invalid mode was accepted"
else
    pass=$((pass + 1))
fi

if bash "$repo_root/scripts/windows/offline/apply.sh" --help | grep -q 'Usage: apply.sh'; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: --help did not print usage"
fi

echo
echo "Offline registry tests (final): $pass passed, $fail failed"
[ "$fail" -eq 0 ]
