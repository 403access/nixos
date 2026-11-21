# Verify the hardened Search/Defender state inside Windows.
#
# Run this in the guest after applying the Developer profile or the offline
# hardening.  It changes nothing and exits 1 if any check fails.
#
#   powershell -ExecutionPolicy Bypass -File verify-minimal.ps1
#   powershell -ExecutionPolicy Bypass -File verify-minimal.ps1 -Json
#
# The offline equivalent reads the SYSTEM/SOFTWARE hives from the host; this
# script is the live regression check for Task Manager and the services view.

[CmdletBinding()]
param(
    [switch]$Json
)

$ErrorActionPreference = 'Continue'
$checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Detail = ''
    )

    $checks.Add([pscustomobject]@{
        Name   = $Name
        Ok     = $Ok
        Detail = $Detail
    })
}

function Get-RegValue {
    param([string]$Path, [string]$Name)

    try {
        return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
    } catch {
        return $null
    }
}

function Test-ServiceState {
    param(
        [string]$Name,
        [string[]]$AllowedStartTypes,
        [string]$ExpectedStatus = 'Stopped'
    )

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        Add-Check "service/$Name" $true 'not present'
        return
    }

    $startType = [string]$service.StartType
    $status = [string]$service.Status
    $startOk = $AllowedStartTypes -contains $startType
    Add-Check "service/$Name start type" $startOk ("{0} (allowed: {1})" -f $startType, ($AllowedStartTypes -join ', '))
    Add-Check "service/$Name status" ($status -eq $ExpectedStatus) $status
}

function Test-NoProcess {
    param([string]$Name)

    $process = Get-Process -Name $Name -ErrorAction SilentlyContinue
    Add-Check "process/$Name" ($null -eq $process) $(if ($process) { 'running' } else { 'not running' })
}

function Invoke-MinimalVerification {
    param([switch]$Json)

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'verify-minimal.ps1 must run inside Windows.' -ForegroundColor Red
    exit 2
}

# --- Windows Search ---------------------------------------------------------

Test-ServiceState -Name WSearch -AllowedStartTypes @('Disabled')
Test-NoProcess -Name SearchHost
Test-NoProcess -Name SearchIndexer
Test-NoProcess -Name SearchProtocolHost
Test-NoProcess -Name SearchFilterHost

$searchDir = Join-Path $env:WINDIR 'SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy'
foreach ($name in 'SearchHost.exe', 'FESearchHost.exe') {
    $exe = Join-Path $searchDir $name
    $bak = "$exe.bak"
    Add-Check "search/$name removed" (-not (Test-Path -LiteralPath $exe)) $(if (Test-Path -LiteralPath $exe) { 'still present' } else { 'missing as expected' })
    Add-Check "search/$name backup" (Test-Path -LiteralPath $bak) $(if (Test-Path -LiteralPath $bak) { 'backup present' } else { 'no .bak backup' })
}

$taskbarMode = Get-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode'
Add-Check 'search/taskbar mode hidden' ($taskbarMode -eq 0) ("SearchboxTaskbarMode={0}" -f $taskbarMode)

# --- Defender services and processes ---------------------------------------

# Windows intentionally changes WinDefend from Disabled to Manual when the
# DisableAntiSpyware policy is active.  Manual is fine as long as the process
# is absent and the binary is renamed.
Test-ServiceState -Name WinDefend -AllowedStartTypes @('Manual', 'Disabled')
Test-ServiceState -Name WdNisSvc -AllowedStartTypes @('Disabled')
Test-ServiceState -Name SecurityHealthService -AllowedStartTypes @('Disabled')
Test-ServiceState -Name wscsvc -AllowedStartTypes @('Disabled')
Test-ServiceState -Name Sense -AllowedStartTypes @('Disabled', 'Manual')

Test-NoProcess -Name MsMpEng
Test-NoProcess -Name MpDefenderCoreService
Test-NoProcess -Name NisSrv

# WdNisDrv is a driver; check its registry start type instead of Get-Service.
$nisDrvStart = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\WdNisDrv' -Name 'Start'
Add-Check 'driver/WdNisDrv disabled' ($nisDrvStart -eq 4) ("Start={0}" -f $nisDrvStart)

# --- Defender binaries ------------------------------------------------------

$defenderRoots = @(
    (Join-Path $env:ProgramFiles 'Windows Defender'),
    (Join-Path $env:ProgramData 'Microsoft\Windows Defender')
)
$activeNames = @('MsMpEng.exe', 'MpDefenderCoreService.exe', 'NisSrv.exe', 'MpCmdRun.exe')
$active = @(
    foreach ($root in $defenderRoots) {
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $activeNames -contains $_.Name }
        }
    }
)
Add-Check 'defender/binaries removed' ($active.Count -eq 0) (($active.FullName -join '; ') -replace [regex]::Escape($env:ProgramFiles), '%ProgramFiles%')

$backups = @(
    foreach ($root in $defenderRoots) {
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.bak' -ErrorAction SilentlyContinue
        }
    }
)
Add-Check 'defender/binaries have backups' ($backups.Count -gt 0) ("{0} .bak file(s)" -f $backups.Count)

# --- Policies and IFEO ------------------------------------------------------

$defenderPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
$policyChecks = @{
    'DisableAntiSpyware' = 1
    'DisableAntiVirus'   = 1
}
foreach ($name in $policyChecks.Keys) {
    $value = Get-RegValue -Path $defenderPolicy -Name $name
    Add-Check "policy/$name" ($value -eq $policyChecks[$name]) ("{0}={1}" -f $name, $value)
}

$rtPolicy = Join-Path $defenderPolicy 'Real-Time Protection'
foreach ($name in 'DisableRealtimeMonitoring', 'DisableBehaviorMonitoring', 'DisableOnAccessProtection', 'DisableScanOnRealtimeEnable') {
    $value = Get-RegValue -Path $rtPolicy -Name $name
    Add-Check "policy/$name" ($value -eq 1) ("{0}={1}" -f $name, $value)
}

$tamper = Get-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name 'TamperProtection'
Add-Check 'policy/TamperProtection off' ($tamper -eq 4) ("TamperProtection={0}" -f $tamper)

$ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
foreach ($name in $activeNames) {
    $debugger = Get-RegValue -Path (Join-Path $ifeo $name) -Name 'Debugger'
    Add-Check "ifeo/$name" (-not [string]::IsNullOrWhiteSpace($debugger)) ("Debugger={0}" -f $debugger)
}

# --- Scheduled tasks --------------------------------------------------------

$taskDir = Join-Path $env:WINDIR 'System32\Tasks\Microsoft\Windows\Windows Defender'
$activeTasks = @()
if (Test-Path -LiteralPath $taskDir) {
    $activeTasks = @(Get-ChildItem -LiteralPath $taskDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*.bak' })
}
Add-Check 'tasks/Defender scans disabled' ($activeTasks.Count -eq 0) (($activeTasks.Name -join '; '))

# --- Report -----------------------------------------------------------------

$failures = @($checks | Where-Object { -not $_.Ok })
$result = [pscustomobject]@{
    Ok       = ($failures.Count -eq 0)
    Failures = $failures
    Checks   = $checks
}

if ($Json) {
    $result | ConvertTo-Json -Depth 4
} else {
    Write-Host 'Hardened Windows check' -ForegroundColor Cyan
    Write-Host ('-' * 64)
    foreach ($check in $checks) {
        $color = if ($check.Ok) { 'Green' } else { 'Red' }
        $mark = if ($check.Ok) { 'PASS' } else { 'FAIL' }
        Write-Host ("{0}  {1,-34} {2}" -f $mark, $check.Name, $check.Detail) -ForegroundColor $color
    }
    Write-Host ''
    if ($result.Ok) {
        Write-Host ("All {0} checks passed." -f $checks.Count) -ForegroundColor Green
    } else {
        Write-Host ("{0} of {1} checks failed." -f $failures.Count, $checks.Count) -ForegroundColor Red
    }
}

if (-not $result.Ok) {
    exit 1
}
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-MinimalVerification -Json:$Json
}