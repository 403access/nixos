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
$searchKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'

function Get-SearchProcesses {
    if (-not (Get-Command Get-Process -ErrorAction SilentlyContinue)) {
        return @()
    }
    return @(Get-Process -Name SearchHost, SearchIndexer, SearchProtocolHost, SearchFilterHost -ErrorAction SilentlyContinue)
}

function Stop-SearchProcesses {
    Get-SearchProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($name in 'SearchHost', 'SearchIndexer', 'SearchProtocolHost', 'SearchFilterHost') {
        & taskkill.exe /F /IM "$name.exe" /T 2>$null | Out-Null
    }
    Start-Sleep -Milliseconds 800
    $remaining = Get-SearchProcesses
    if ($remaining.Count -gt 0) {
        Write-Host ("    still running: {0}" -f (($remaining | Select-Object -ExpandProperty ProcessName -Unique) -join ', ')) -ForegroundColor Yellow
        Write-Host '    SearchHost is the Start-menu UI and may restart when Start/Task Manager is opened.' -ForegroundColor Yellow
    } else {
        Write-Host '    search processes stopped.' -ForegroundColor Green
    }
}

function Set-TaskbarSearchMode {
    param([int]$Mode)

    try {
        if (-not (Test-Path -LiteralPath $searchKey)) {
            New-Item -Path $searchKey -Force | Out-Null
        }
        New-ItemProperty -Path $searchKey -Name 'SearchboxTaskbarMode' -Value $Mode `
            -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $searchKey -Name 'BingSearchEnabled' -Value 0 `
            -PropertyType DWord -Force | Out-Null
    } catch {
        Write-Warning ("Could not update the taskbar search mode: {0}" -f $_.Exception.Message)
    }
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

function Disable-Search {
    $service = Get-Service -Name WSearch -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Warning 'WSearch is not present on this system.'
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $stateFile) -and [string]$service.StartType -ne 'Disabled') {
            if (-not (Test-Path -LiteralPath $stateDir)) {
                New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
            }
            $currentMode = $null
            try {
                $currentMode = (Get-ItemProperty -Path $searchKey -Name 'SearchboxTaskbarMode' -ErrorAction Stop).SearchboxTaskbarMode
            } catch {
                $currentMode = $null
            }
            [pscustomobject]@{
                StartType = [string]$service.StartType
                SearchboxTaskbarMode = $currentMode
            } | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
        }

        Set-Service -Name WSearch -StartupType Disabled -ErrorAction Stop
        Stop-Service -Name WSearch -Force -ErrorAction SilentlyContinue
        Set-TaskbarSearchMode -Mode 0
        Stop-SearchProcesses
        Write-Host 'Windows Search disabled (WSearch), taskbar search hidden, processes stopped.' -ForegroundColor Green
        Write-Host 'SearchHost.exe is the UI; Start menu search can start it again.' -ForegroundColor Yellow
        Write-Host 'Restart Explorer or sign out for the taskbar change to show.'
        Write-Host 'Re-enable with -Enable or enable-search.bat.'
    } catch {
        Write-Host ("Could not disable Windows Search: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Enable-Search {
    $service = Get-Service -Name WSearch -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Warning 'WSearch is not present on this system.'
        return
    }

    $startType = 'Automatic'
    $taskbarMode = 2
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $saved = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            if ($saved.StartType -and [string]$saved.StartType -ne 'Disabled') {
                $startType = [string]$saved.StartType
            }
            if ($null -ne $saved.SearchboxTaskbarMode) {
                $taskbarMode = [int]$saved.SearchboxTaskbarMode
            }
        } catch {
            Write-Warning 'Could not read the saved search state; using defaults.'
        }
    }

    try {
        Set-Service -Name WSearch -StartupType $startType -ErrorAction Stop
        Start-Service -Name WSearch -ErrorAction SilentlyContinue
        Set-TaskbarSearchMode -Mode $taskbarMode
        Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
        Write-Host ("Windows Search enabled ({0}); taskbar search restored. Indexing may take a while." -f $startType) -ForegroundColor Green
    } catch {
        Write-Host ("Could not enable Windows Search: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Invoke-SearchToggle {
    param(
        [switch]$Disable,
        [switch]$Enable,
        [switch]$Status
    )

    if ($Status) {
        Show-SearchStatus
        return
    }

    if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
        Write-Warning 'The service cmdlets are not available on this system.'
        return
    }

    if ($Disable) {
        Disable-Search
        return
    }

    if ($Enable) {
        Enable-Search
        return
    }

    Show-SearchStatus
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-SearchToggle -Disable:$Disable -Enable:$Enable -Status:$Status
}