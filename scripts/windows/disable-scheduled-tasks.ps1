# Disable the scheduled tasks that wake the disk for telemetry, compatibility
# checks, feedback, disk diagnostics, Maps updates and Windows tips.
#
# Windows Update, Defender, backup and maintenance tasks are deliberately left
# alone.  Re-enable a task with:
#   Get-ScheduledTask -TaskPath '\Microsoft\Windows\...' | Enable-ScheduledTask

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$paths = @(
    @{ Path = '\Microsoft\Windows\Application Experience\'; Reason = 'compatibility appraiser and program data uploader' }
    @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Reason = 'CEIP consolidation' }
    @{ Path = '\Microsoft\Windows\Feedback\'; Reason = 'feedback prompts' }
    @{ Path = '\Microsoft\Windows\Autochk\'; Reason = 'autochk proxy' }
    @{ Path = '\Microsoft\Windows\CloudExperienceHost\'; Reason = 'cloud content host' }
    @{ Path = '\Microsoft\Windows\DiskDiagnostic\'; Reason = 'disk diagnostic data collector' }
    @{ Path = '\Microsoft\Windows\PI\'; Reason = 'software inventory / SQM' }
    @{ Path = '\Microsoft\Windows\RetailDemo\'; Reason = 'retail demo' }
    @{ Path = '\Microsoft\Windows\Maps\'; Reason = 'Maps updates and toasts' }
    @{ Path = '\Microsoft\Windows\Windows Error Reporting\'; Reason = 'error report queue' }
    @{ Path = '\Microsoft\Windows\Maintenance\'; Reason = 'WinSAT performance assessment' }
    @{ Path = '\Microsoft\Windows\Power Efficiency Diagnostics\'; Reason = 'power analysis' }
)

$disabled = 0
$failed = 0

foreach ($entry in $paths) {
    Write-Host "Disabling tasks under $($entry.Path) ($($entry.Reason)) ..."

    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskPath -like "$($entry.Path)*" }

    if (-not $tasks) {
        Write-Host '    none present'
        continue
    }

    foreach ($task in $tasks) {
        try {
            Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop | Out-Null
            Write-Host "    disabled: $($task.TaskPath)$($task.TaskName)"
            $disabled++
        } catch {
            Write-Warning "    failed: $($task.TaskPath)$($task.TaskName): $($_.Exception.Message)"
            $failed++
        }
    }
}

Write-Host ''
Write-Host "Disabled $disabled task(s); $failed failed."
Write-Host 'Kept enabled: Windows Update, Defender, backup, Storage Sense and disk maintenance.'