# Report, disable or enable Microsoft Defender.
#
# The Developer profile keeps Defender enabled by design. This file offers an
# explicit separate action: disabling requires Tamper Protection to be off,
# needs a reboot, and is unsupported by Microsoft.

[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$Disable,
    [switch]$Enable,
    [switch]$Open,
    [switch]$OpenTamper
)

$ErrorActionPreference = 'Continue'

function Test-Admin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Set-Dword {
    param([string]$Path, [string]$Name, [int]$Value)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

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
    Write-Host 'The Developer profile keeps Defender enabled.' -ForegroundColor Yellow
    Write-Host 'Use Disable only if you accept the security trade-off and Tamper Protection is off.'
}

function Disable-Defender {
    if (-not (Test-Admin)) {
        Write-Warning 'Disabling Defender needs an elevated shell.'
        return
    }
    if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
        Write-Warning 'Defender cmdlets are not available on this system.'
        return
    }

    $status = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($status -and $status.IsTamperProtected) {
        Write-Host 'Tamper Protection is enabled; refusing to change Defender.' -ForegroundColor Yellow
        Write-Host 'Windows Security > Virus & threat protection > Manage settings > Tamper Protection.'
        Write-Host 'Turn that off first, then retry.'
        try {
            Start-Process -FilePath 'windowsdefender://threatsettings' -ErrorAction Stop
            Write-Host 'Opened the Virus & threat protection settings page.'
        } catch {
            try {
                Start-Process -FilePath 'ms-settings:windowsdefender' -ErrorAction Stop
            } catch {
                Write-Host 'Could not open Windows Security automatically.'
            }
        }
        return
    }

    Write-Host 'Disabling Defender real-time protection and services ...'
    try {
        Set-MpPreference -DisableRealtimeMonitoring $true -DisableBehaviorMonitoring $true `
            -DisableScriptScanning $true -DisableIOAVProtection $true -ErrorAction SilentlyContinue
    } catch {
        Write-Warning ("Set-MpPreference failed: {0}" -f $_.Exception.Message)
    }

    Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' 'DisableAntiSpyware' 1
    Set-Dword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' 'DisableAntiVirus' 1

    foreach ($name in 'WinDefend', 'WdNisSvc') {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $service) {
            continue
        }
        try {
            Set-Service -Name $name -StartupType Disabled -ErrorAction Stop
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
            Write-Host ("disabled: {0}" -f $name)
        } catch {
            Write-Warning ("Could not disable {0}: {1}" -f $name, $_.Exception.Message)
        }
    }

    Write-Host ''
    Write-Host 'Defender changes applied. Reboot the guest to stop the remaining processes.' -ForegroundColor Yellow
    Write-Host 'This is unsupported; Windows updates may re-enable Defender.'
}

function Enable-Defender {
    if (-not (Test-Admin)) {
        Write-Warning 'Enabling Defender needs an elevated shell.'
        return
    }

    Write-Host 'Re-enabling Microsoft Defender ...'
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
    foreach ($name in 'DisableAntiSpyware', 'DisableAntiVirus') {
        Remove-ItemProperty -Path $policy -Name $name -Force -ErrorAction SilentlyContinue
    }

    foreach ($name in 'WinDefend', 'WdNisSvc') {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $service) {
            continue
        }
        try {
            $startType = if ($name -eq 'WinDefend') { 'Automatic' } else { 'Manual' }
            Set-Service -Name $name -StartupType $startType -ErrorAction Stop
            Start-Service -Name $name -ErrorAction SilentlyContinue
            Write-Host ("enabled: {0} ({1})" -f $name, $startType)
        } catch {
            Write-Warning ("Could not enable {0}: {1}" -f $name, $_.Exception.Message)
        }
    }

    if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
        try {
            Set-MpPreference -DisableRealtimeMonitoring $false -DisableBehaviorMonitoring $false `
                -DisableScriptScanning $false -DisableIOAVProtection $false -ErrorAction SilentlyContinue
        } catch {
            Write-Warning ("Set-MpPreference failed: {0}" -f $_.Exception.Message)
        }
    }

    Write-Host 'Defender re-enabled. Reboot if the service did not start.' -ForegroundColor Green
}

function Invoke-DefenderAction {
    param(
        [switch]$Status,
        [switch]$Disable,
        [switch]$Enable,
        [switch]$Open,
        [switch]$OpenTamper
    )

    if ($OpenTamper) {
        try {
            Start-Process -FilePath 'windowsdefender://threatsettings' -ErrorAction Stop
        } catch {
            try {
                Start-Process -FilePath 'ms-settings:windowsdefender' -ErrorAction Stop
            } catch {
                Write-Host ("Could not open the Defender settings: {0}" -f $_.Exception.Message) -ForegroundColor Red
            }
        }
        return
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

    if ($Disable) {
        Disable-Defender
        return
    }

    if ($Enable) {
        Enable-Defender
        return
    }

    Show-DefenderStatus
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-DefenderAction -Status:$Status -Disable:$Disable -Enable:$Enable -Open:$Open -OpenTamper:$OpenTamper
}