# Apply the full slim-desktop profile in one pass.
#
# Runs the same scripts as the individual helper-CD launchers, in the order
# that makes sense: appearance, AI surfaces, telemetry, background tasks,
# services, gaming, cleanup.  A reboot is required afterwards.
#
# Use -SkipCleanup on a first pass, then run cleanup separately.  Add
# -SkipGaming when the Xbox app is needed.  The -IncludeSearch /
# -IncludeSysMain / -ComponentCleanup / -ResetBase switches are forwarded to
# the matching child script.

[CmdletBinding()]
param(
    [switch]$SkipCleanup,
    [switch]$SkipGaming,
    [switch]$IncludeSearch,
    [switch]$IncludeSysMain,
    [switch]$ComponentCleanup,
    [switch]$ResetBase
)

$ErrorActionPreference = 'Continue'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning 'Not running elevated; service, policy and DISM steps will fail.'
}

$logDir = Join-Path $env:ProgramData 'WindowsSlim'
try {
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
} catch {
    Write-Warning "Could not create the log directory: $($_.Exception.Message)"
}
$log = Join-Path $logDir 'windows-minimal.log'
try {
    Start-Transcript -Path $log -Append -Force | Out-Null
} catch {
    Write-Warning "Could not start transcript: $($_.Exception.Message)"
}

function Invoke-Step {
    param(
        [int]$Number,
        [int]$Total,
        [string]$Label,
        [string]$Script,
        [hashtable]$Arguments = @{}
    )

    $path = Join-Path -Path $PSScriptRoot -ChildPath $Script
    Write-Host ''
    Write-Host "===== [$Number/$Total] $Label ====="

    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warning "missing script: $path"
        return
    }

    try {
        & $path @Arguments
    } catch {
        Write-Warning "$Label failed: $($_.Exception.Message)"
    }
}

$total = 7

Invoke-Step -Number 1 -Total $total -Label 'Visual effects' -Script 'disable-visuals.ps1'
Invoke-Step -Number 2 -Total $total -Label 'AI, search and suggestions' -Script 'disable-ai.ps1'
Invoke-Step -Number 3 -Total $total -Label 'Telemetry' -Script 'disable-telemetry.ps1'
Invoke-Step -Number 4 -Total $total -Label 'Scheduled tasks' -Script 'disable-scheduled-tasks.ps1'

$serviceArgs = @{}
if ($IncludeSearch) { $serviceArgs['IncludeSearch'] = $true }
if ($IncludeSysMain) { $serviceArgs['IncludeSysMain'] = $true }
Invoke-Step -Number 5 -Total $total -Label 'Services' -Script 'optimize-services.ps1' -Arguments $serviceArgs

if ($SkipGaming) {
    Write-Host ''
    Write-Host '===== [6/7] Gaming features skipped (-SkipGaming) ====='
} else {
    Invoke-Step -Number 6 -Total $total -Label 'Gaming features' -Script 'disable-gaming.ps1'
}

if ($SkipCleanup) {
    Write-Host ''
    Write-Host '===== [7/7] Cleanup skipped (-SkipCleanup) ====='
} else {
    $cleanupArgs = @{}
    if ($ComponentCleanup) { $cleanupArgs['ComponentCleanup'] = $true }
    if ($ResetBase) { $cleanupArgs['ResetBase'] = $true }
    Invoke-Step -Number 7 -Total $total -Label 'Cleanup' -Script 'cleanup.ps1' -Arguments $cleanupArgs
}

Write-Host ''
Write-Host 'Slim profile applied. Reboot the guest to finish.'
Write-Host "Transcript: $log"
Write-Host 'Revert individual tweaks from Settings > Accessibility > Visual effects,'
Write-Host 'Settings > Privacy & security, or by re-enabling services and tasks.'

try {
    Stop-Transcript | Out-Null
} catch {
    # Nothing to do if the transcript never started.
}