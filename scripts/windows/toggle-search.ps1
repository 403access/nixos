# Disable or enable Windows Search.
#
# WSearch is the service that builds the index. SearchHost.exe is the per-user
# search UI; stopping it closes the current search window, but Windows can start
# it again when an app asks for search. Disabling WSearch is the persistent
# switch.

[CmdletBinding()]
param(
    [switch]$Disable,
    [switch]$Enable,
    [switch]$Status
)

$ErrorActionPreference = 'Continue'
$programData = if ($env:ProgramData) { $env:ProgramData } else { [IO.Path]::GetTempPath() }
$stateDir = Join-Path $programData 'WindowsSlim'
$stateFile = Join-Path $stateDir 'search-state.json'

function Get-SearchProcesses {
    if (-not (Get-Command Get-Process -ErrorAction SilentlyContinue)) {
        return @()
    }
    return @(Get-Process -Name SearchHost, SearchIndexer, SearchProtocolHost, SearchFilterHost -ErrorAction SilentlyContinue)
}

function Stop-SearchProcesses {
    Get-SearchProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Show-SearchStatus {
    Write-Host 'Windows Search' -ForegroundColor Cyan
    Write-Host ('-' * 64)

    if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
        Write-Host 'Service cmdlets are not available.'
    } else {
        $service = Get-Service -Name WSearch -ErrorAction SilentlyContinue
        if ($service) {
            Write-Host ("WSearch        : {0}/{1}" -f $service.Status, $service.StartType)
        } else {
            Write-Host 'WSearch        : missing'
        }
    }

    $processes = Get-SearchProcesses
    if ($processes.Count -eq 0) {
        Write-Host 'SearchHost     : not running'
    } else {
        Write-Host ("SearchHost     : {0}" -f (($processes | Select-Object -ExpandProperty ProcessName -Unique) -join ', '))
    }
    Write-Host ("Saved state    : {0}" -f (Test-Path -LiteralPath $stateFile))
    Write-Host ''
    Write-Host 'WSearch is the service; SearchHost.exe is the per-user UI process.'
}

if ($Status) {
    Show-SearchStatus
    return
}

if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
    Write-Warning 'The service cmdlets are not available on this system.'
    return
}

$service = Get-Service -Name WSearch -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Warning 'WSearch is not present on this system.'
    return
}

if ($Disable) {
    try {
        if (-not (Test-Path -LiteralPath $stateFile) -and [string]$service.StartType -ne 'Disabled') {
            if (-not (Test-Path -LiteralPath $stateDir)) {
                New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
            }
            [pscustomobject]@{ StartType = [string]$service.StartType } |
                ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
        }

        Set-Service -Name WSearch -StartupType Disabled -ErrorAction Stop
        Stop-Service -Name WSearch -Force -ErrorAction SilentlyContinue
        Stop-SearchProcesses
        Write-Host 'Windows Search disabled (WSearch) and search processes stopped.' -ForegroundColor Green
        Write-Host 'SearchHost.exe is the UI; it may start again until WSearch stays disabled.' -ForegroundColor Yellow
        Write-Host 'Re-enable with -Enable or enable-search.bat.'
    } catch {
        Write-Host ("Could not disable Windows Search: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    return
}

if ($Enable) {
    $startType = 'Automatic'
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $saved = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            if ($saved.StartType -and [string]$saved.StartType -ne 'Disabled') {
                $startType = [string]$saved.StartType
            }
        } catch {
            Write-Warning 'Could not read the saved search state; using Automatic.'
        }
    }

    try {
        Set-Service -Name WSearch -StartupType $startType -ErrorAction Stop
        Start-Service -Name WSearch -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
        Write-Host ("Windows Search enabled ({0}). Indexing may take a while." -f $startType) -ForegroundColor Green
    } catch {
        Write-Host ("Could not enable Windows Search: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    return
}

Show-SearchStatus