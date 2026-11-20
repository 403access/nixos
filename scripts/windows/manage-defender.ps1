# Report Microsoft Defender status and open Windows Security.
#
# This helper deliberately does not disable Defender. Tamper Protection blocks
# scripted changes on current Windows builds, and Defender is the security
# baseline for this image.

[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$Open
)

$ErrorActionPreference = 'Continue'

function Show-DefenderStatus {
    Write-Host 'Microsoft Defender' -ForegroundColor Cyan
    Write-Host ('-' * 64)

    if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
        Write-Host 'Defender cmdlets are not available on this system.'
        return
    }

    $status = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if (-not $status) {
        Write-Host 'Could not read Defender status.'
        return
    }

    Write-Host ("Antivirus enabled        : {0}" -f $status.AntivirusEnabled)
    Write-Host ("Real-time protection     : {0}" -f $status.RealTimeProtectionEnabled)
    Write-Host ("Tamper protection        : {0}" -f $status.IsTamperProtected)
    Write-Host ("Signature version        : {0}" -f $status.AntivirusSignatureVersion)
    Write-Host ("Signature last updated   : {0}" -f $status.AntivirusSignatureLastUpdated)

    if (Get-Command Get-MpPreference -ErrorAction SilentlyContinue) {
        $prefs = Get-MpPreference -ErrorAction SilentlyContinue
        if ($prefs) {
            Write-Host ("Realtime disabled flag   : {0}" -f $prefs.DisableRealtimeMonitoring)
            if ($prefs.ExclusionPath) {
                Write-Host ("Exclusions               : {0}" -f (($prefs.ExclusionPath) -join '; '))
            }
        }
    }

    if (Get-Command Get-Service -ErrorAction SilentlyContinue) {
        foreach ($name in 'WinDefend', 'WdNisSvc', 'SecurityHealthService') {
            $service = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($service) {
                Write-Host ("{0,-24} : {1}/{2}" -f $name, $service.Status, $service.StartType)
            }
        }
    }

    Write-Host ''
    Write-Host 'This helper does not disable Defender.' -ForegroundColor Yellow
    Write-Host 'Tamper Protection blocks scripted changes; use Windows Security if you really need to change it.'
}

if ($Open) {
    try {
        Start-Process -FilePath 'windowsdefender://' -ErrorAction Stop
    } catch {
        try {
            Start-Process -FilePath 'ms-settings:windowsdefender' -ErrorAction Stop
        } catch {
            Write-Host ("Could not open Windows Security: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
    }
    return
}

Show-DefenderStatus