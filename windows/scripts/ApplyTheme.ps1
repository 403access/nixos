# Apply a staged Windows theme for the current user.
#
# SetupComplete.ps1 registers this script in the machine-wide RunOnce key, so
# Windows runs it after the first user's desktop (and Explorer) is available.
# It only changes HKCU, so it does not need an elevated token.

[CmdletBinding()]
param(
    [string]$ConfigPath = "$env:ProgramData\WindowsSlim\themes.json",
    [switch]$RestartExplorer
)

$ErrorActionPreference = 'Continue'
$LogPath = Join-Path $env:TEMP 'windows-theme.log'

try {
    Start-Transcript -Path $LogPath -Append -Force | Out-Null
} catch {
    Write-Warning "Could not start transcript: $($_.Exception.Message)"
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message"
}

function Get-ConfiguredTheme {
    param($Config)

    foreach ($candidate in @($Config.default)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    foreach ($theme in @($Config.themes)) {
        foreach ($file in @($theme.files)) {
            if ($file.path -and (Test-Path -LiteralPath $file.path)) {
                return $file.path
            }
        }
    }

    return $null
}

try {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Warning "Theme config not found: $ConfigPath"
        return
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $themePath = Get-ConfiguredTheme -Config $config

    if (-not $themePath) {
        Write-Warning "No installed theme file from $ConfigPath is present"
        return
    }

    Write-Step "Applying Windows theme"
    Write-Host "    theme: $themePath"
    if ($config.defaultDisplayName) {
        Write-Host "    name:  $($config.defaultDisplayName)"
    }

    $verifier = Get-ItemProperty `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\winlogon.exe' `
        -Name VerifierDlls `
        -ErrorAction SilentlyContinue
    if (-not $verifier -or $verifier.VerifierDlls -ne 'SecureUxTheme4.dll') {
        Write-Warning "SecureUxTheme is not staged; Windows may ignore the custom visual style"
    }

    $themeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes'
    if (-not (Test-Path -Path $themeKey)) {
        New-Item -Path $themeKey -Force | Out-Null
    }
    New-ItemProperty `
        -Path $themeKey `
        -Name CurrentTheme `
        -Value $themePath `
        -PropertyType String `
        -Force | Out-Null

    try {
        # Double-clicking a .theme file is the documented way to apply it.
        Start-Process -FilePath $themePath -ErrorAction Stop
    } catch {
        Write-Warning "Could not invoke the .theme file: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 4
    Start-Process `
        -FilePath "$env:SystemRoot\System32\rundll32.exe" `
        -ArgumentList 'user32.dll,UpdatePerUserSystemParameters' `
        -Wait `
        -ErrorAction SilentlyContinue | Out-Null

    if ($RestartExplorer) {
        Write-Step "Restarting Explorer"
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process -FilePath "$env:SystemRoot\explorer.exe"
        }
    }

    Write-Step "Theme applied"
    Write-Host "Log: $LogPath"
} catch {
    Write-Warning "Theme application failed: $($_.Exception.Message)"
} finally {
    try {
        Stop-Transcript | Out-Null
    } catch {
        # Nothing to do.
    }
}
