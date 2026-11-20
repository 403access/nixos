# Apply personal File Explorer preferences for the current user.
#
# 1. Show hidden files and folders.
# 2. Show every file extension, including known types.
# 3. Open File Explorer in "This PC" instead of Home/Quick access.
#
# These are HKCU settings, so run the menu once per Windows account.
# Protected operating system files stay hidden unless -ShowProtectedSystemFiles
# is passed.

[CmdletBinding()]
param(
    [switch]$ShowProtectedSystemFiles,
    [switch]$RestartExplorer
)

$ErrorActionPreference = 'Continue'
$advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

function Set-Dword {
    param([string]$Path, [string]$Name, [int]$Value)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

Write-Host 'Showing hidden files and folders ...'
Set-Dword $advanced Hidden 1

if ($ShowProtectedSystemFiles) {
    Write-Host 'Showing protected operating system files (not recommended).' -ForegroundColor Yellow
    Set-Dword $advanced ShowSuperHidden 1
} else {
    Set-Dword $advanced ShowSuperHidden 0
}

Write-Host 'Showing all file extensions ...'
Set-Dword $advanced HideFileExt 0

Write-Host 'Opening File Explorer in This PC ...'
Set-Dword $advanced LaunchTo 1

Write-Host ''
Write-Host 'Applied:'
Get-ItemProperty -Path $advanced |
    Select-Object Hidden, ShowSuperHidden, HideFileExt, LaunchTo |
    Format-List

Write-Host 'Hidden = 1 means shown; HideFileExt = 0 means shown; LaunchTo = 1 means This PC.'
Write-Host 'Unknown extensions are shown as well; Windows only hides extensions for registered types.'

if ($RestartExplorer) {
    Write-Host ''
    Write-Host 'Restarting Explorer ...'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Write-Host 'Explorer restarted.'
} else {
    Write-Host ''
    Write-Host 'Sign out and back in, or restart Explorer, to apply every window.'
}