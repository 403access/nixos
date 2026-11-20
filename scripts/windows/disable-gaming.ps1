# Disable Game DVR, the Xbox Game Bar overlay and the Xbox background services.
#
# This is opt-in: it also signs the user out of the Xbox app and Game Pass
# titles that rely on Xbox services.  Steam, Epic and standalone games keep
# working.  Re-enable services with Set-Service and launch the Xbox app once
# to restore the registry values.

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

Write-Host 'Disabling Game DVR capture and the Game Bar overlay ...'
Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' AllowGameDVR 0
Set-Dword 'HKCU:\System\GameConfigStore' GameDVR_Enabled 0
Set-Dword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' AppCaptureEnabled 0
Set-Dword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' HistoricalCaptureEnabled 0
Set-Dword 'HKCU:\Software\Microsoft\GameBar' AutoGameModeEnabled 0
Set-Dword 'HKCU:\Software\Microsoft\GameBar' UseGameBar 0
Set-Dword 'HKCU:\Software\Microsoft\GameBar' ShowStartupPanel 0

Write-Host 'Disabling Xbox services ...'
Disable-ServiceSafe -Name XblAuthManager -Label 'Xbox Live Auth Manager'
Disable-ServiceSafe -Name XblGameSave   -Label 'Xbox Live Game Save'
Disable-ServiceSafe -Name XboxGipSvc    -Label 'Xbox Accessory Management'
Disable-ServiceSafe -Name XboxNetApiSvc -Label 'Xbox Live Networking'

Write-Host 'Disabling the Xbox scheduled task ...'
Get-ScheduledTask -TaskPath '\Microsoft\Windows\XblGameSave\*' -ErrorAction SilentlyContinue |
    ForEach-Object {
        try {
            Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction Stop | Out-Null
            Write-Host "    disabled: $($_.TaskPath)$($_.TaskName)"
        } catch {
            Write-Warning "    failed: $($_.TaskPath)$($_.TaskName): $($_.Exception.Message)"
        }
    }

Write-Host ''
Write-Host 'Kept enabled: the graphics driver, DirectX and fullscreen optimizations.'
Write-Host 'Steam and standalone games are unaffected; the Xbox app is not.'