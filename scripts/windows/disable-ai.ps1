# Remove the Windows 11 AI, search and suggestion surfaces that run in the
# background or pull content from the internet.
#
# Covers Copilot, Recall, Click to Do, Widgets, taskbar Chat, web results in
# Start search, Start/Explorer recommendations and the consumer "tips" that
# Windows installs on its own.  It does not touch Store, Edge, Defender or
# Windows Update.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Set-Dword {
    param(
        [string]$Path,
        [string]$Name,
        [int]$Value,
        [switch]$Optional
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    } catch {
        if ($Optional) {
            Write-Host ("    skipped (protected by Windows): {0}" -f $Name) -ForegroundColor Yellow
        } else {
            Write-Warning ("    could not set {0}: {1}" -f $Name, $_.Exception.Message)
        }
    }
}

function Set-Text {
    param([string]$Path, [string]$Name, [string]$Value)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

$policies = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
$current = 'HKCU:\Software\Microsoft\Windows\CurrentVersion'
$advanced = "$current\Explorer\Advanced"
$search = "$current\SearchSettings"
$delivery = "$current\ContentDeliveryManager"

Write-Host 'Disabling Copilot ...'
Set-Dword "$policies\WindowsCopilot" TurnOffWindowsCopilot 1
Set-Dword 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' TurnOffWindowsCopilot 1
Set-Dword $advanced ShowCopilotButton 0

Write-Host 'Disabling Recall and Click to Do ...'
Set-Dword "$policies\WindowsAI" DisableAIDataAnalysis 1
Set-Dword "$policies\WindowsAI" AllowRecallEnablement 0
Set-Dword "$policies\WindowsAI" DisableClickToDo 1

Write-Host 'Removing Widgets and taskbar Chat ...'
Set-Dword "$policies\Dsh" AllowNewsAndInterests 0
Set-Dword "$policies\Dsh" DisableWidgetsBoard 1
Set-Dword "$policies\Windows Chat" ChatIcon 3
# Recent Windows builds protect these two per-user values; keep them for older
# builds and skip them quietly when the shell refuses the write.
Set-Dword $advanced TaskbarDa 0 -Optional
Set-Dword $advanced TaskbarMn 0 -Optional

Write-Host 'Disabling web and cloud results in Start search ...'
Set-Dword "$policies\Windows Search" DisableWebSearch 1
Set-Dword "$policies\Windows Search" ConnectedSearchUseWeb 0
Set-Dword "$policies\Windows Search" AllowCloudSearch 0
Set-Dword "$policies\Windows Search" EnableDynamicContentInWSB 0
Set-Dword "$policies\Explorer" DisableSearchBoxSuggestions 1
Set-Dword $search IsDynamicSearchBoxEnabled 0
Set-Dword $search IsMSACloudSearchEnabled 0
Set-Dword $search IsAADCloudSearchEnabled 0
Set-Dword $search IsDeviceSearchHistoryEnabled 0

Write-Host 'Disabling Start, Explorer and Settings recommendations ...'
Set-Dword $advanced Start_IrisRecommendations 0
Set-Dword $advanced Start_AccountNotifications 0
Set-Dword $advanced ShowSyncProviderNotifications 0
Set-Dword "$current\UserProfileEngagement" ScoobeSystemSettingEnabled 0

Set-Dword "$policies\CloudContent" DisableWindowsConsumerFeatures 1
Set-Dword "$policies\CloudContent" DisableConsumerAccountStateContent 1
Set-Dword "$policies\CloudContent" DisableSoftLanding 1
Set-Dword "$policies\CloudContent" DisableCloudOptimizedContent 1

Set-Dword $delivery SilentInstalledAppsEnabled 0
Set-Dword $delivery PreInstalledAppsEnabled 0
Set-Dword $delivery OemPreInstalledAppsEnabled 0
Set-Dword $delivery SystemPaneSuggestionsEnabled 0
Set-Dword $delivery SoftLandingEnabled 0
Set-Dword $delivery SubscribedContentEnabled 0

# Feature-specific "suggestions" toggles; unknown IDs are ignored by Windows.
foreach ($id in 310093, 338388, 338389, 338393, 353694) {
    Set-Dword $delivery "SubscribedContent-${id}Enabled" 0
}

Write-Host ''
Write-Host 'Kept enabled: Store, Edge, Defender, Windows Update.'
Write-Host 'On recent builds the Widgets/Chat policy values do the work; some taskbar'
Write-Host 'registry values are protected by Windows and cannot be changed directly.'
Write-Host 'Sign out and back in for the Start menu and taskbar changes to apply.'