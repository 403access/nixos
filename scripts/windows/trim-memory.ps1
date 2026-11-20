[CmdletBinding()]
param(
    [switch]$DisableSearch,
    [switch]$DisableSysMain
)

$ErrorActionPreference = 'Continue'

Write-Host '== Memory before =='
Get-CimInstance Win32_OperatingSystem |
    Select-Object @{n='TotalGB';e={[math]::Round($_.TotalVisibleMemorySize/1MB,1)}},
                  @{n='FreeGB';e={[math]::Round($_.FreePhysicalMemory/1MB,1)}}
Get-Process | Sort-Object WS -Descending |
    Select-Object -First 12 Name,@{n='MB';e={[int]($_.WS/1MB)}} |
    Format-Table -AutoSize

Write-Host 'Removing OneDrive from startup and stopping it ...'
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (Get-ItemProperty -Path $run -Name OneDrive -ErrorAction SilentlyContinue) {
    Remove-ItemProperty -Path $run -Name OneDrive
}
Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Write-Host 'Disabling Widgets ...'
$dsh = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'
New-Item -Path $dsh -Force | Out-Null
Set-ItemProperty -Path $dsh -Name AllowNewsAndInterests -Value 0 -Type DWord

Write-Host 'Disabling Recall analysis ...'
$ai = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
New-Item -Path $ai -Force | Out-Null
Set-ItemProperty -Path $ai -Name DisableAIDataAnalysis -Value 1 -Type DWord

Write-Host 'Disabling background apps for the current user ...'
$bg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
New-Item -Path $bg -Force | Out-Null
Set-ItemProperty -Path $bg -Name GlobalUserDisabled -Value 1 -Type DWord

if ($DisableSearch) {
    Write-Host 'Disabling Windows Search indexing ...'
    Set-Service -Name WSearch -StartupType Disabled
    Stop-Service -Name WSearch -Force -ErrorAction SilentlyContinue
}

if ($DisableSysMain) {
    Write-Host 'Disabling SysMain ...'
    Set-Service -Name SysMain -StartupType Disabled
    Stop-Service -Name SysMain -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'Kept enabled: Defender, Windows Update, VBS/Core Isolation.'
Write-Host 'Sign out or reboot for the policies to take effect.'