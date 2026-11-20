# Reclaim disk space from caches and logs.
#
# Default run touches only disposable data: user/system temp, Delivery
# Optimization cache, thumbnail cache, WER reports and CBS logs.  Longer
# operations are opt-in:
#   -WindowsUpdateCache  clear SoftwareDistribution\Download
#   -ComponentCleanup    DISM component cleanup (minutes)
#   -ResetBase           also remove superseded update backups (no uninstall)
#   -DryRun              print what would be removed

[CmdletBinding()]
param(
    [switch]$WindowsUpdateCache,
    [switch]$ComponentCleanup,
    [switch]$ResetBase,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

if ($ResetBase) {
    $ComponentCleanup = $true
}

$before = (Get-PSDrive -Name C -ErrorAction SilentlyContinue).Free

function Clear-Tree {
    param([string]$Path, [string]$Label)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "    missing: $Label ($Path)"
        return
    }

    $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    if ($items.Count -eq 0) {
        Write-Host "    empty: $Label"
        return
    }

    if ($DryRun) {
        Write-Host "    would remove $($items.Count) item(s): $Label"
        return
    }

    foreach ($item in $items) {
        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "    cleared $($items.Count) item(s): $Label"
}

function Clear-Files {
    param([string]$Path, [string]$Filter, [string]$Label)

    $files = @(Get-ChildItem -LiteralPath $Path -Filter $Filter -Force -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        Write-Host "    none: $Label"
        return
    }

    if ($DryRun) {
        Write-Host "    would remove $($files.Count) file(s): $Label"
        return
    }

    foreach ($file in $files) {
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    }
    Write-Host "    removed $($files.Count) file(s): $Label"
}

Write-Host 'Clearing temp files ...'
Clear-Tree -Path ([System.IO.Path]::GetTempPath()) -Label 'user temp'
Clear-Tree -Path "$env:SystemRoot\Temp" -Label 'Windows temp'

Write-Host 'Clearing Delivery Optimization cache ...'
if ($DryRun) {
    Write-Host '    skipped in dry run'
} elseif (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
    try {
        Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
        Write-Host '    cleared'
    } catch {
        Write-Warning "    failed: $($_.Exception.Message)"
    }
} else {
    Write-Host '    cmdlet not available on this build'
}

Write-Host 'Clearing thumbnail cache (rebuilds on demand) ...'
$thumbDir = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
Clear-Files -Path $thumbDir -Filter 'thumbcache_*.db' -Label 'thumbcache'

Write-Host 'Clearing Windows Error Reporting data ...'
$wer = "$env:ProgramData\Microsoft\Windows\WER"
foreach ($folder in 'ReportArchive', 'ReportQueue', 'Temp') {
    Clear-Tree -Path (Join-Path $wer $folder) -Label "WER $folder"
}

Write-Host 'Clearing CBS logs ...'
Clear-Files -Path "$env:SystemRoot\Logs\CBS" -Filter '*.log' -Label 'CBS logs'
Clear-Files -Path "$env:SystemRoot\Logs\CBS" -Filter '*.cab' -Label 'CBS cabinets'

if ($WindowsUpdateCache) {
    Write-Host 'Clearing the Windows Update download cache ...'
    if ($DryRun) {
        Write-Host '    skipped in dry run'
    } else {
        try {
            Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
            Stop-Service -Name bits -Force -ErrorAction SilentlyContinue
            Clear-Tree -Path "$env:SystemRoot\SoftwareDistribution\Download" -Label 'WU download cache'
        } finally {
            Start-Service -Name wuauserv -ErrorAction SilentlyContinue
            Start-Service -Name bits -ErrorAction SilentlyContinue
        }
    }
}

if ($ComponentCleanup) {
    Write-Host 'Running DISM component cleanup (this can take several minutes) ...'
    if ($DryRun) {
        Write-Host '    skipped in dry run'
    } else {
        $dismArgs = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
        if ($ResetBase) {
            $dismArgs += '/ResetBase'
            Write-Host '    including /ResetBase; installed updates can no longer be uninstalled'
        }
        & dism.exe @dismArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "    dism exited with $LASTEXITCODE"
        }
    }
}

$after = (Get-PSDrive -Name C -ErrorAction SilentlyContinue).Free
if ($before -and $after) {
    $freed = [math]::Round(($after - $before) / 1GB, 2)
    Write-Host ''
    Write-Host ("Free space on C: {0} GiB -> {1} GiB ({2} GiB freed)" -f `
        [math]::Round($before / 1GB, 2), [math]::Round($after / 1GB, 2), $freed)
}
Write-Host 'Done.'