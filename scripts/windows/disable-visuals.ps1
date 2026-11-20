# Turn off the expensive Windows 11 shell effects for the current user.
#
# This is the per-account part of a slim image: animations, transparency,
# shadows, menu fades and Aero Peek are what make an idle desktop feel busy
# and keep the GPU/CPU awake.  ClearType and hardware acceleration stay on.
#
# Revert through Settings > Accessibility > Visual effects, or by selecting
# "Let Windows choose" in Settings > System > About > Advanced system settings
# > Performance.

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

function Set-Text {
    param([string]$Path, [string]$Name, [string]$Value)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

function Set-Binary {
    param([string]$Path, [string]$Name, [byte[]]$Value)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType Binary -Force | Out-Null
}

$desktop = 'HKCU:\Control Panel\Desktop'
$metrics = 'HKCU:\Control Panel\Desktop\WindowMetrics'
$explorer = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
$advanced = "$explorer\Advanced"
$visualFx = "$explorer\VisualEffects"
$dwm = 'HKCU:\Software\Microsoft\Windows\DWM'
$personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'

Write-Host 'Selecting the "Adjust for best performance" visual profile ...'
Set-Dword $visualFx VisualFXSetting 2

# 0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00 is the mask Windows writes when
# every optional animation and shadow is cleared.
Set-Binary $desktop UserPreferencesMask ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00))

Write-Host 'Disabling window, menu and taskbar animations ...'
Set-Text $desktop DragFullWindows '0'
Set-Text $desktop MenuShowDelay '0'
Set-Text $metrics MinAnimate '0'
Set-Dword $desktop SmoothScroll 0
Set-Dword $advanced TaskbarAnimations 0
Set-Dword $advanced ListviewAlphaSelect 0
Set-Dword $advanced ListviewShadow 0

Write-Host 'Disabling Aero Peek and live thumbnail caching ...'
Set-Dword $advanced EnableAeroPeek 0
Set-Dword $dwm EnableAeroPeek 0
Set-Dword $dwm AlwaysHibernateThumbnails 0

Write-Host 'Disabling transparency and acrylic effects ...'
Set-Dword $personalize EnableTransparency 0
Set-Dword $dwm ColorPrevalence 0

# The per-feature checkboxes are what the Settings page reads back, so write
# them explicitly instead of relying on the performance mask alone.
$effects = @(
    'AnimateControlsInCascadeMinMax',
    'AnimateMinMax',
    'ComboBoxAnimation',
    'CursorShadow',
    'DropShadow',
    'ListBoxSmoothScrolling',
    'MenuAnimation',
    'SelectionFade',
    'TaskbarAnimations',
    'TooltipAnimation',
    'TooltipFade',
    'UIElements'
)

foreach ($effect in $effects) {
    Set-Dword "$visualFx\$effect" DefaultValue 0
}

Write-Host ''
Write-Host 'Kept enabled: ClearType font smoothing and GPU acceleration.'
Write-Host 'Sign out and back in (or restart Explorer) for every window to use the new settings.'