#!/usr/bin/env bash
# Offline registry helpers for the Windows slim image.
#
# These functions operate on hive files, not on a mounted disk.  The caller is
# responsible for shutting down the VM, mounting the Windows partition and
# unmounting it afterwards.  `apply.sh` does that; the test suite calls these
# functions directly with synthetic hives.
#
# Requires: hivexregedit (libhivex-bin / nixpkgs.hivex).

HIVEXREGEDIT="${HIVEXREGEDIT:-hivexregedit}"

hive_export() {
    local prefix="$1" hive="$2" key="$3"
    "$HIVEXREGEDIT" --export --prefix "$prefix" "$hive" "$key" 2>/dev/null || true
}

hive_merge() {
    local prefix="$1" hive="$2" file="$3"
    "$HIVEXREGEDIT" --merge --prefix "$prefix" "$hive" "$file"
}

hive_current_control_set() {
    local hive="$1" hex
    hex="$(hive_export 'HKEY_LOCAL_MACHINE\SYSTEM' "$hive" 'Select' |
        sed -n 's/.*"Current"=dword:0*\([0-9a-fA-F]*\).*/\1/p' | tail -1)"
    [ -n "$hex" ] || hex=1
    printf 'ControlSet%03d' "$((0x$hex))"
}

hive_get_dword() {
    local prefix="$1" hive="$2" key="$3" name="$4"
    hive_export "$prefix" "$hive" "$key" |
        sed -n "s/.*\"$name\"=dword:0*\([0-9a-fA-F]*\).*/\1/p" | tail -1
}

hive_has_value() {
    local prefix="$1" hive="$2" key="$3" name="$4"
    hive_export "$prefix" "$hive" "$key" | grep -q "\"$name\"="
}

hive_set_dword() {
    local prefix="$1" hive="$2" key="$3" name="$4" value="$5"
    local reg
    reg="$(mktemp)"
    printf '[%s]\n"%s"=dword:%08x\n' "$key" "$name" "$value" > "$reg"
    hive_merge "$prefix" "$hive" "$reg"
    local rc=$?
    rm -f "$reg"
    return $rc
}

hive_set_string() {
    local prefix="$1" hive="$2" key="$3" name="$4" value="$5"
    local reg
    reg="$(mktemp)"
    printf '[%s]\n"%s"="%s"\n' "$key" "$name" "${value//\\/\\\\}" > "$reg"
    hive_merge "$prefix" "$hive" "$reg"
    local rc=$?
    rm -f "$reg"
    return $rc
}

offline_backup_hive() {
    local hive="$1" backup="$2"
    if [ -e "$backup" ]; then
        echo "backup already exists: $backup"
        return 0
    fi
    cp -a "$hive" "$backup"
    echo "backup: $backup"
}

offline_rename_files() {
    local root="$1" pattern="$2"
    [ -d "$root" ] || return 0
    find "$root" -type f -iname "$pattern" ! -iname '*.bak' -print0 2>/dev/null |
        while IFS= read -r -d '' file; do
            mv "$file" "$file.bak"
            echo "renamed: ${file#"$root"/} -> .bak"
        done
}

offline_disable_defender_binaries() {
    local windows_root="$1"
    local roots=(
        "$windows_root/Program Files/Windows Defender"
        "$windows_root/ProgramData/Microsoft/Windows Defender"
    )
    local name root
    for root in "${roots[@]}"; do
        for name in 'MsMpEng.exe' 'MpDefenderCoreService.exe' 'NisSrv.exe' 'MpCmdRun.exe'; do
            offline_rename_files "$root" "$name"
        done
    done
}

offline_disable_defender_tasks() {
    local windows_root="$1"
    local tasks="$windows_root/Windows/System32/Tasks/Microsoft/Windows/Windows Defender"
    local task
    [ -d "$tasks" ] || return 0
    for task in "$tasks"/*; do
        [ -e "$task" ] || continue
        case "$task" in
            *.bak) continue ;;
        esac
        mv "$task" "$task.bak"
        echo "task disabled: ${task#"$windows_root"/}"
    done
}

offline_patch_defender() {
    local system_hive="$1" software_hive="$2" windows_root="$3"
    local cs reg_sys reg_soft
    cs="$(hive_current_control_set "$system_hive")"
    echo "CurrentControlSet: $cs"

    reg_sys="$(mktemp)"
    cat > "$reg_sys" <<EOF
[$cs\\Services\\WinDefend]
"Start"=dword:00000004

[$cs\\Services\\WdNisSvc]
"Start"=dword:00000004

[$cs\\Services\\WdNisDrv]
"Start"=dword:00000004

[$cs\\Services\\SecurityHealthService]
"Start"=dword:00000004

[$cs\\Services\\wscsvc]
"Start"=dword:00000004

[$cs\\Services\\Sense]
"Start"=dword:00000004
EOF
    if ! hive_merge 'HKEY_LOCAL_MACHINE\SYSTEM' "$system_hive" "$reg_sys"; then
        rm -f "$reg_sys"
        echo "ERROR: could not merge SYSTEM services" >&2
        return 1
    fi
    rm -f "$reg_sys"

    reg_soft="$(mktemp)"
    cat > "$reg_soft" <<'EOF'
[Policies\Microsoft\Windows Defender]
"DisableAntiSpyware"=dword:00000001
"DisableAntiVirus"=dword:00000001

[Policies\Microsoft\Windows Defender\Real-Time Protection]
"DisableRealtimeMonitoring"=dword:00000001
"DisableBehaviorMonitoring"=dword:00000001
"DisableOnAccessProtection"=dword:00000001
"DisableScanOnRealtimeEnable"=dword:00000001

[Policies\Microsoft\Windows Defender\UX Configuration]
"Notification_Suppress"=dword:00000001

[Policies\Microsoft\Windows Defender Security Center]

[Policies\Microsoft\Windows Defender Security Center\Notifications]
"DisableNotifications"=dword:00000001
"DisableEnhancedNotifications"=dword:00000001

[Microsoft\Windows Defender\Features]
"TamperProtection"=dword:00000004

[Microsoft\Windows Defender]
"DisableAntiSpyware"=dword:00000001

[Microsoft\Windows Defender\Real-Time Protection]
"DisableRealtimeMonitoring"=dword:00000001

[Microsoft\Windows NT\CurrentVersion\Image File Execution Options\MsMpEng.exe]
"Debugger"="C:\\Windows\\System32\\defender-disabled.exe"

[Microsoft\Windows NT\CurrentVersion\Image File Execution Options\MpDefenderCoreService.exe]
"Debugger"="C:\\Windows\\System32\\defender-disabled.exe"

[Microsoft\Windows NT\CurrentVersion\Image File Execution Options\NisSrv.exe]
"Debugger"="C:\\Windows\\System32\\defender-disabled.exe"

[Microsoft\Windows NT\CurrentVersion\Image File Execution Options\MpCmdRun.exe]
"Debugger"="C:\\Windows\\System32\\defender-disabled.exe"
EOF
    if ! hive_merge 'HKEY_LOCAL_MACHINE\SOFTWARE' "$software_hive" "$reg_soft"; then
        rm -f "$reg_soft"
        echo "ERROR: could not merge Defender policies" >&2
        return 1
    fi
    rm -f "$reg_soft"

    offline_disable_defender_binaries "$windows_root"
    offline_disable_defender_tasks "$windows_root"
}

offline_patch_search() {
    local system_hive="$1" windows_root="$2"
    local cs reg
    cs="$(hive_current_control_set "$system_hive")"
    echo "CurrentControlSet: $cs"

    reg="$(mktemp)"
    cat > "$reg" <<EOF
[$cs\\Services\\WSearch]
"Start"=dword:00000004
EOF
    if ! hive_merge 'HKEY_LOCAL_MACHINE\SYSTEM' "$system_hive" "$reg"; then
        rm -f "$reg"
        echo "ERROR: could not merge WSearch" >&2
        return 1
    fi
    rm -f "$reg"

    local systemapps="$windows_root/Windows/SystemApps"
    local name
    for name in 'SearchHost.exe' 'FESearchHost.exe' 'MiniSearchHost.exe' 'SearchApp.exe'; do
        offline_rename_files "$systemapps" "$name"
    done
}

offline_verify_defender() {
    local system_hive="$1" software_hive="$2" windows_root="$3"
    local failures=0 cs value name root
    cs="$(hive_current_control_set "$system_hive")"

    for name in WinDefend WdNisSvc WdNisDrv SecurityHealthService wscsvc Sense; do
        value="$(hive_get_dword 'HKEY_LOCAL_MACHINE\SYSTEM' "$system_hive" "$cs\\Services\\$name" 'Start')"
        if [ "${value:-}" != "4" ]; then
            echo "FAIL: $name Start=${value:-missing} (expected 4)"
            failures=$((failures + 1))
        fi
    done

    for name in DisableAntiSpyware DisableAntiVirus; do
        value="$(hive_get_dword 'HKEY_LOCAL_MACHINE\SOFTWARE' "$software_hive" 'Policies\Microsoft\Windows Defender' "$name")"
        if [ "${value:-}" != "1" ]; then
            echo "FAIL: policy $name=${value:-missing} (expected 1)"
            failures=$((failures + 1))
        fi
    done

    for name in DisableRealtimeMonitoring DisableBehaviorMonitoring DisableOnAccessProtection DisableScanOnRealtimeEnable; do
        value="$(hive_get_dword 'HKEY_LOCAL_MACHINE\SOFTWARE' "$software_hive" 'Policies\Microsoft\Windows Defender\Real-Time Protection' "$name")"
        if [ "${value:-}" != "1" ]; then
            echo "FAIL: real-time policy $name=${value:-missing} (expected 1)"
            failures=$((failures + 1))
        fi
    done

    value="$(hive_get_dword 'HKEY_LOCAL_MACHINE\SOFTWARE' "$software_hive" 'Microsoft\Windows Defender\Features' 'TamperProtection')"
    if [ "${value:-}" != "4" ]; then
        echo "FAIL: TamperProtection=${value:-missing} (expected 4)"
        failures=$((failures + 1))
    fi

    for name in MsMpEng.exe MpDefenderCoreService.exe NisSrv.exe MpCmdRun.exe; do
        if ! hive_has_value 'HKEY_LOCAL_MACHINE\SOFTWARE' "$software_hive" "Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\$name" 'Debugger'; then
            echo "FAIL: IFEO $name Debugger missing"
            failures=$((failures + 1))
        fi
    done

    local active
    active="$(find "$windows_root/Program Files/Windows Defender" "$windows_root/ProgramData/Microsoft/Windows Defender" \
        -type f \( -iname 'MsMpEng.exe' -o -iname 'MpDefenderCoreService.exe' -o -iname 'NisSrv.exe' -o -iname 'MpCmdRun.exe' \) \
        -print 2>/dev/null || true)"
    if [ -n "$active" ]; then
        echo "FAIL: active Defender binaries:"
        echo "$active"
        failures=$((failures + 1))
    fi

    local tasks="$windows_root/Windows/System32/Tasks/Microsoft/Windows/Windows Defender"
    if [ -d "$tasks" ]; then
        local active_tasks
        active_tasks="$(find "$tasks" -maxdepth 1 -type f ! -name '*.bak' -print 2>/dev/null || true)"
        if [ -n "$active_tasks" ]; then
            echo "FAIL: active Defender tasks:"
            echo "$active_tasks"
            failures=$((failures + 1))
        fi
    fi

    if [ "$failures" -eq 0 ]; then
        echo "Defender verification: OK"
        return 0
    fi
    echo "Defender verification: $failures failure(s)"
    return 1
}

offline_verify_search() {
    local system_hive="$1" windows_root="$2"
    local failures=0 cs value
    cs="$(hive_current_control_set "$system_hive")"
    value="$(hive_get_dword 'HKEY_LOCAL_MACHINE\SYSTEM' "$system_hive" "$cs\\Services\\WSearch" 'Start')"
    if [ "${value:-}" != "4" ]; then
        echo "FAIL: WSearch Start=${value:-missing} (expected 4)"
        failures=$((failures + 1))
    fi

    local systemapps="$windows_root/Windows/SystemApps"
    local name active
    for name in 'SearchHost.exe' 'FESearchHost.exe' 'MiniSearchHost.exe' 'SearchApp.exe'; do
        active="$(find "$systemapps" -type f -iname "$name" -print 2>/dev/null || true)"
        if [ -n "$active" ]; then
            echo "FAIL: active search binary:"
            echo "$active"
            failures=$((failures + 1))
        fi
    done

    if [ "$failures" -eq 0 ]; then
        echo "Search verification: OK"
        return 0
    fi
    echo "Search verification: $failures failure(s)"
    return 1
}