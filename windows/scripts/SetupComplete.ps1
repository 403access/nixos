# Windows 11 first-boot debloat
#
# This script is copied into the image as
# C:\Windows\Setup\Scripts\SetupComplete.ps1 and runs once after Windows Setup.
# It removes provisioned AppX packages through the supported cmdlets rather than
# deleting files from Program Files\WindowsApps.

[CmdletBinding()]
param(
    [ValidateSet('safe', 'lean', 'micro')]
    [string]$ProfileName = 'lean',

    [string]$ThemeConfig = "$env:ProgramData\WindowsSlim\themes.json",

    [string]$LogPath = "$env:SystemRoot\Temp\win11-slim.log"
)

$ErrorActionPreference = 'Continue'

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

function Remove-AppxPattern {
    param([string]$Pattern)

    Write-Step "AppX: $Pattern*"

    $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.PackageName -like "$Pattern*" }

    foreach ($package in $provisioned) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop | Out-Null
            Write-Host "    provisioned removed: $($package.PackageName)"
        } catch {
            Write-Warning "    provisioned failed: $($package.PackageName): $($_.Exception.Message)"
        }
    }

    $installed = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$Pattern*" }

    foreach ($package in $installed) {
        try {
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
            Write-Host "    installed removed: $($package.Name)"
        } catch {
            Write-Warning "    installed failed: $($package.Name): $($_.Exception.Message)"
        }
    }
}

function Disable-ServiceSafe {
    param([string]$Name)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Host "    service not present: $Name"
        return
    }

    try {
        Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        Write-Host "    service disabled: $Name"
    } catch {
        Write-Warning "    service failed: ${Name}: $($_.Exception.Message)"
    }
}

function Disable-TaskPath {
    param([string]$Path)

    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskPath -like "$Path*" } |
        ForEach-Object {
            try {
                Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction Stop | Out-Null
                Write-Host "    task disabled: $($_.TaskPath)$($_.TaskName)"
            } catch {
                Write-Warning "    task failed: $($_.TaskPath)$($_.TaskName): $($_.Exception.Message)"
            }
        }
}

function Set-RegValue {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'DWord'
    )

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Protect-ThemeDirectory {
    param([string]$ConfigPath)

    $themeDir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $themeDir)) {
        return
    }

    # The folder is read by the first-logon script, so users need read/execute
    # but must not be able to replace the script or the theme manifest.
    try {
        & icacls.exe $themeDir /inheritance:r `
            /grant:r '*S-1-5-18:(OI)(CI)F' `
            '*S-1-5-32-544:(OI)(CI)F' `
            '*S-1-5-32-545:(OI)(CI)RX' `
            /T /C 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "    icacls exited with $LASTEXITCODE for $themeDir"
        } else {
            Write-Host "    restricted theme data ACL: $themeDir"
        }
    } catch {
        Write-Warning "    could not restrict theme data ACL: $($_.Exception.Message)"
    }
}

function Register-ThemeFirstLogon {
    param([string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return
    }

    Protect-ThemeDirectory -ConfigPath $ConfigPath

    $applyScript = Join-Path $env:ProgramData 'WindowsSlim\ApplyTheme.ps1'
    if (-not (Test-Path -LiteralPath $applyScript)) {
        Write-Warning "Theme config exists but ApplyTheme.ps1 is missing: $applyScript"
        return
    }

    $command = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$applyScript`""
    $runOnce = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path -Path $runOnce)) {
        New-Item -Path $runOnce -Force | Out-Null
    }

    New-ItemProperty `
        -Path $runOnce `
        -Name 'WindowsSlimTheme' `
        -Value $command `
        -PropertyType String `
        -Force | Out-Null

    Write-Host "    theme will be applied at the first logon"
    Write-Host "    command: $command"
}

$leanPatterns = @(
    'Microsoft.3DBuilder',
    'Microsoft.BingFinance',
    'Microsoft.BingNews',
    'Microsoft.BingSports',
    'Microsoft.BingWeather',
    'Microsoft.GamingApp',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.Microsoft3DViewer',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.MixedReality.Portal',
    'Microsoft.Office.OneNote',
    'Microsoft.OneConnect',
    'Microsoft.OutlookForWindows',
    'Microsoft.People',
    'Microsoft.PowerAutomateDesktop',
    'Microsoft.Print3D',
    'Microsoft.SkypeApp',
    'Microsoft.Todos',
    'Microsoft.Wallet',
    'Microsoft.WindowsAlarms',
    'Microsoft.WindowsCommunicationsApps',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps',
    'Microsoft.WindowsSoundRecorder',
    'Microsoft.Xbox',
    'Microsoft.YourPhone',
    'Microsoft.ZuneMusic',
    'Microsoft.ZuneVideo',
    'Clipchamp.Clipchamp',
    'MicrosoftTeams',
    'MSTeams'
)

$microPatterns = @(
    'Microsoft.OneDriveSync',
    'Microsoft.StorePurchaseApp',
    'Microsoft.WindowsCamera',
    'Microsoft.WindowsStore',
    'Microsoft.Windows.DevHome'
)

if ($ProfileName -eq 'safe') {
    Write-Step 'safe profile: no AppX or service removal'
} else {
    $patterns = $leanPatterns
    if ($ProfileName -eq 'micro') {
        $patterns = $leanPatterns + $microPatterns
    }

    Write-Step "Removing consumer AppX packages ($ProfileName)"
    foreach ($pattern in $patterns) {
        Remove-AppxPattern -Pattern $pattern
    }
}

if ($ProfileName -in @('lean', 'micro')) {
    Write-Step 'Disabling telemetry, consumer features and Copilot policies'

    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsSpotlightFeatures' 1
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableThirdPartySuggestions' 1
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 0
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 1
    Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0

    Write-Step 'Disabling telemetry services'
    foreach ($service in @('DiagTrack', 'dmwappushservice', 'RetailDemo', 'Fax', 'RemoteRegistry', 'MapsBroker')) {
        Disable-ServiceSafe -Name $service
    }

    Write-Step 'Disabling telemetry scheduled tasks'
    foreach ($path in @(
        '\Microsoft\Windows\Application Experience\',
        '\Microsoft\Windows\Customer Experience Improvement Program\',
        '\Microsoft\Windows\Feedback\Siuf\',
        '\Microsoft\Windows\DiskDiagnostic\',
        '\Microsoft\Windows\Autochk\'
    )) {
        Disable-TaskPath -Path $path
    }
    Get-ScheduledTask -TaskName 'QueueReporting' -TaskPath '\Microsoft\Windows\Windows Error Reporting\' -ErrorAction SilentlyContinue |
        ForEach-Object {
            Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue | Out-Null
        }
}

if ($ProfileName -eq 'micro') {
    Write-Step 'Applying micro profile services'
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1

    foreach ($service in @(
        'WSearch',
        'SysMain',
        'PhoneSvc',
        'PcaSvc',
        'WalletService',
        'XblAuthManager',
        'XblGameSave',
        'XboxGipSvc',
        'XboxNetApiSvc'
    )) {
        Disable-ServiceSafe -Name $service
    }

    Write-Step 'Removing OneDrive and disabling hibernation'
    $oneDriveSetup = Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'
    if (Test-Path $oneDriveSetup) {
        Start-Process -FilePath $oneDriveSetup -ArgumentList '/uninstall' -Wait -NoNewWindow -ErrorAction SilentlyContinue
    }
    powercfg.exe /hibernate off 2>$null

    Write-Step 'Micro profile complete: Store, Xbox, search and OneDrive removal requested'
}

Write-Step 'Configuring Windows themes'
if (Test-Path -LiteralPath $ThemeConfig) {
    Register-ThemeFirstLogon -ConfigPath $ThemeConfig
} else {
    Write-Host '    no theme configuration found'
}

Write-Step "Finished profile: $ProfileName"
Write-Host "Log: $LogPath"
try {
    Stop-Transcript | Out-Null
} catch {
    # Nothing to do.
}
