# Reduce Windows diagnostic data, feedback prompts and activity tracking.
#
# Windows Home floors the telemetry policy at "Basic"; the service shutdown is
# still useful there.  Defender, Windows Update, the event log and error
# reporting to the local console stay enabled.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Set-Dword {
    param([string]$Path, [string]$Name, [int]$Value)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Disable-ServiceSafe {
    param([string]$Name, [string]$Label)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Host "    not present: $Label ($Name)"
        return
    }

    try {
        Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        Write-Host "    disabled: $Label ($Name)"
    } catch {
        Write-Warning "    failed: $Label ($Name): $($_.Exception.Message)"
    }
}

$policies = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
$current = 'HKCU:\Software\Microsoft\Windows\CurrentVersion'

Write-Host 'Disabling telemetry services ...'
Disable-ServiceSafe -Name DiagTrack -Label 'Connected User Experiences and Telemetry'
Disable-ServiceSafe -Name dmwappushservice -Label 'Device Management WAP Push'

Write-Host 'Setting diagnostic data to the minimum ...'
Set-Dword "$policies\DataCollection" AllowTelemetry 0
Set-Dword "$policies\DataCollection" DoNotShowFeedbackNotifications 1
Set-Dword 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' AllowTelemetry 0

Write-Host 'Disabling Windows Error Reporting uploads ...'
Set-Dword "$policies\Windows Error Reporting" Disabled 1
Set-Dword "$policies\Windows Error Reporting" DontSendAdditionalData 1

Write-Host 'Disabling advertising ID and tailored experiences ...'
Set-Dword "$policies\AdvertisingInfo" DisabledByGroupPolicy 1
Set-Dword "$current\AdvertisingInfo" Enabled 0
Set-Dword "$current\Privacy" TailoredExperiencesWithDiagnosticDataEnabled 0

Write-Host 'Disabling activity history and cloud sync ...'
Set-Dword "$policies\System" EnableActivityFeed 0
Set-Dword "$policies\System" PublishUserActivities 0
Set-Dword "$policies\System" UploadUserActivities 0

Write-Host 'Silencing feedback prompts ...'
Set-Dword 'HKCU:\Software\Microsoft\Siuf\Rules' NumberOfSIUFInPeriod 0
Set-Dword "$current\Diagnostics\DiagTrack" ShowedToastAtLevel 1

Write-Host ''
Write-Host 'Kept enabled: Defender, Windows Update, Event Log, local WER logging.'
Write-Host 'Windows Home may still report "Basic" diagnostics; that is by design.'