# Deactivate or remove OneDrive, stock apps and stock services.
#
# OneDrive can be disabled without touching files, or uninstalled with the
# official OneDriveSetup.exe. Stock AppX packages are removed through the
# supported cmdlets. Services are only disabled; their original startup types
# are saved so they can be restored.
#
# Examples:
#   .\trim-stock.ps1 -List
#   .\trim-stock.ps1 -OneDrive Disable -Apps Lean -Services Lean
#   .\trim-stock.ps1 -OneDrive Remove -Apps Aggressive
#   .\trim-stock.ps1 -RestoreServices
#   .\trim-stock.ps1 -RestoreOneDrive

[CmdletBinding()]
param(
    [ValidateSet('None', 'Disable', 'Remove')]
    [string]$OneDrive = 'None',

    [ValidateSet('None', 'Lean', 'Aggressive')]
    [string]$Apps = 'None',

    [ValidateSet('None', 'Lean', 'Balanced', 'Aggressive')]
    [string]$Services = 'None',

    [switch]$RestoreOneDrive,
    [switch]$RestoreServices,
    [switch]$List,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$programData = if ($env:ProgramData) { $env:ProgramData } else { [IO.Path]::GetTempPath() }
$stateDir = Join-Path $programData 'WindowsSlim'
$serviceState = Join-Path $stateDir 'stock-services.json'
$oneDriveState = Join-Path $stateDir 'onedrive-state.json'
$oneDrivePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
$oneDriveRun = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

$leanApps = @(
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

$aggressiveApps = $leanApps + @(
    'Microsoft.StorePurchaseApp',
    'Microsoft.WindowsCamera',
    'Microsoft.WindowsStore',
    'Microsoft.Windows.DevHome'
)

$leanServices = @(
    [pscustomobject]@{ Name = 'DiagTrack'; Type = 'Disabled'; Label = 'Connected User Experiences and Telemetry' },
    [pscustomobject]@{ Name = 'dmwappushservice'; Type = 'Disabled'; Label = 'Device Management WAP Push' },
    [pscustomobject]@{ Name = 'RetailDemo'; Type = 'Disabled'; Label = 'Retail Demo' },
    [pscustomobject]@{ Name = 'Fax'; Type = 'Disabled'; Label = 'Fax' },
    [pscustomobject]@{ Name = 'Spooler'; Type = 'Disabled'; Label = 'Print Spooler' },
    [pscustomobject]@{ Name = 'PrintScanBrokerService'; Type = 'Disabled'; Label = 'Print Scan Broker' },
    [pscustomobject]@{ Name = 'PrintDeviceConfigurationService'; Type = 'Disabled'; Label = 'Print Device Configuration' },
    [pscustomobject]@{ Name = 'PrintNotify'; Type = 'Disabled'; Label = 'Print Notification' },
    [pscustomobject]@{ Name = 'RemoteRegistry'; Type = 'Disabled'; Label = 'Remote Registry' },
    [pscustomobject]@{ Name = 'MapsBroker'; Type = 'Disabled'; Label = 'Downloaded Maps Manager' },
    [pscustomobject]@{ Name = 'WMPNetworkSvc'; Type = 'Disabled'; Label = 'Windows Media Player sharing' },
    [pscustomobject]@{ Name = 'WalletService'; Type = 'Disabled'; Label = 'Wallet Service' },
    [pscustomobject]@{ Name = 'XblAuthManager'; Type = 'Disabled'; Label = 'Xbox Live Auth Manager' },
    [pscustomobject]@{ Name = 'XblGameSave'; Type = 'Disabled'; Label = 'Xbox Live Game Save' },
    [pscustomobject]@{ Name = 'XboxGipSvc'; Type = 'Disabled'; Label = 'Xbox Accessory Management' },
    [pscustomobject]@{ Name = 'XboxNetApiSvc'; Type = 'Disabled'; Label = 'Xbox Live Networking' },
    [pscustomobject]@{ Name = 'PhoneSvc'; Type = 'Manual'; Label = 'Phone Service' },
    [pscustomobject]@{ Name = 'PcaSvc'; Type = 'Manual'; Label = 'Program Compatibility Assistant' },
    [pscustomobject]@{ Name = 'WpcMonSvc'; Type = 'Manual'; Label = 'Parental Controls' }
)

$balancedServices = @(
    [pscustomobject]@{ Name = 'DiagTrack'; Type = 'Disabled'; Label = 'Connected User Experiences and Telemetry' },
    [pscustomobject]@{ Name = 'dmwappushservice'; Type = 'Disabled'; Label = 'Device Management WAP Push' },
    [pscustomobject]@{ Name = 'RetailDemo'; Type = 'Disabled'; Label = 'Retail Demo' },
    [pscustomobject]@{ Name = 'Fax'; Type = 'Disabled'; Label = 'Fax' },
    [pscustomobject]@{ Name = 'RemoteRegistry'; Type = 'Disabled'; Label = 'Remote Registry' },
    [pscustomobject]@{ Name = 'MapsBroker'; Type = 'Disabled'; Label = 'Downloaded Maps Manager' },
    [pscustomobject]@{ Name = 'WMPNetworkSvc'; Type = 'Disabled'; Label = 'Windows Media Player sharing' },
    [pscustomobject]@{ Name = 'WalletService'; Type = 'Disabled'; Label = 'Wallet Service' },
    [pscustomobject]@{ Name = 'PhoneSvc'; Type = 'Manual'; Label = 'Phone Service' },
    [pscustomobject]@{ Name = 'PcaSvc'; Type = 'Manual'; Label = 'Program Compatibility Assistant' },
    [pscustomobject]@{ Name = 'WpcMonSvc'; Type = 'Manual'; Label = 'Parental Controls' }
)

$aggressiveServices = @(
    $leanServices + $balancedServices + @(
    [pscustomobject]@{ Name = 'WSearch'; Type = 'Disabled'; Label = 'Windows Search' },
    [pscustomobject]@{ Name = 'SysMain'; Type = 'Disabled'; Label = 'SysMain' },
    [pscustomobject]@{ Name = 'bthserv'; Type = 'Disabled'; Label = 'Bluetooth Support' },
    [pscustomobject]@{ Name = 'BTAGService'; Type = 'Disabled'; Label = 'Bluetooth Audio Gateway' },
    [pscustomobject]@{ Name = 'BthAvctpSvc'; Type = 'Disabled'; Label = 'Bluetooth AVCTP' },
    [pscustomobject]@{ Name = 'WlanSvc'; Type = 'Disabled'; Label = 'WLAN AutoConfig' },
    [pscustomobject]@{ Name = 'dot3svc'; Type = 'Disabled'; Label = 'Wired AutoConfig' },
    [pscustomobject]@{ Name = 'icssvc'; Type = 'Disabled'; Label = 'Windows Mobile Hotspot' },
    [pscustomobject]@{ Name = 'SharedAccess'; Type = 'Disabled'; Label = 'Internet Connection Sharing' },
    [pscustomobject]@{ Name = 'lfsvc'; Type = 'Disabled'; Label = 'Geolocation' },
    [pscustomobject]@{ Name = 'SensorService'; Type = 'Disabled'; Label = 'Sensor Service' },
    [pscustomobject]@{ Name = 'SensrSvc'; Type = 'Disabled'; Label = 'Sensor Monitoring' },
    [pscustomobject]@{ Name = 'SensorDataService'; Type = 'Disabled'; Label = 'Sensor Data' },
    [pscustomobject]@{ Name = 'WbioSrvc'; Type = 'Disabled'; Label = 'Windows Biometric' },
    [pscustomobject]@{ Name = 'SEMgrSvc'; Type = 'Disabled'; Label = 'Payments and NFC/SE Manager' },
    [pscustomobject]@{ Name = 'stisvc'; Type = 'Disabled'; Label = 'Windows Image Acquisition' },
    [pscustomobject]@{ Name = 'WiaRpc'; Type = 'Disabled'; Label = 'Still Image Devices' },
    [pscustomobject]@{ Name = 'FrameServer'; Type = 'Disabled'; Label = 'Camera Frame Server' },
    [pscustomobject]@{ Name = 'FrameServerMonitor'; Type = 'Disabled'; Label = 'Camera Frame Server Monitor' },
    [pscustomobject]@{ Name = 'ScardSvr'; Type = 'Disabled'; Label = 'Smart Card' },
    [pscustomobject]@{ Name = 'ScDeviceEnum'; Type = 'Disabled'; Label = 'Smart Card Device Enumeration' },
    [pscustomobject]@{ Name = 'ScPolicySvc'; Type = 'Disabled'; Label = 'Smart Card Removal Policy' },
    [pscustomobject]@{ Name = 'CertPropSvc'; Type = 'Disabled'; Label = 'Certificate Propagation' },
    [pscustomobject]@{ Name = 'WerSvc'; Type = 'Disabled'; Label = 'Windows Error Reporting' },
    [pscustomobject]@{ Name = 'DPS'; Type = 'Disabled'; Label = 'Diagnostic Policy Service' },
    [pscustomobject]@{ Name = 'WdiServiceHost'; Type = 'Disabled'; Label = 'Diagnostic Service Host' },
    [pscustomobject]@{ Name = 'WdiSystemHost'; Type = 'Disabled'; Label = 'Diagnostic System Host' },
    [pscustomobject]@{ Name = 'WpnService'; Type = 'Disabled'; Label = 'Windows Push Notifications' },
    [pscustomobject]@{ Name = 'DoSvc'; Type = 'Disabled'; Label = 'Delivery Optimization' },
    [pscustomobject]@{ Name = 'FDResPub'; Type = 'Disabled'; Label = 'Function Discovery Resource Publication' },
    [pscustomobject]@{ Name = 'fdPHost'; Type = 'Disabled'; Label = 'Function Discovery Provider Host' },
    [pscustomobject]@{ Name = 'SSDPSRV'; Type = 'Disabled'; Label = 'SSDP Discovery' },
    [pscustomobject]@{ Name = 'upnphost'; Type = 'Disabled'; Label = 'UPnP Device Host' },
    [pscustomobject]@{ Name = 'WinRM'; Type = 'Disabled'; Label = 'Windows Remote Management' },
    [pscustomobject]@{ Name = 'Wecsvc'; Type = 'Disabled'; Label = 'Windows Event Collector' },
    [pscustomobject]@{ Name = 'RemoteAccess'; Type = 'Disabled'; Label = 'Routing and Remote Access' },
    [pscustomobject]@{ Name = 'NcaSvc'; Type = 'Disabled'; Label = 'Network Connectivity Assistant' },
    [pscustomobject]@{ Name = 'IKEEXT'; Type = 'Disabled'; Label = 'IKE and AuthIP IPsec' },
    [pscustomobject]@{ Name = 'PolicyAgent'; Type = 'Disabled'; Label = 'IPsec Policy Agent' },
    [pscustomobject]@{ Name = 'RpcLocator'; Type = 'Disabled'; Label = 'RPC Locator' },
    [pscustomobject]@{ Name = 'CscService'; Type = 'Disabled'; Label = 'Offline Files' },
    [pscustomobject]@{ Name = 'SDRSVC'; Type = 'Disabled'; Label = 'Windows Backup' },
    [pscustomobject]@{ Name = 'wbengine'; Type = 'Disabled'; Label = 'Block Level Backup Engine' },
    [pscustomobject]@{ Name = 'DsmSvc'; Type = 'Disabled'; Label = 'Device Setup Manager' },
    [pscustomobject]@{ Name = 'AJRouter'; Type = 'Disabled'; Label = 'AllJoyn Router' },
    [pscustomobject]@{ Name = 'GamingServices'; Type = 'Disabled'; Label = 'Gaming Services' },
    [pscustomobject]@{ Name = 'GamingServicesNet'; Type = 'Disabled'; Label = 'Gaming Services Network' },
    [pscustomobject]@{ Name = 'CloudBackupRestoreSvc'; Type = 'Disabled'; Label = 'Cloud Backup and Restore' }
    )
) | Sort-Object Name -Unique

function Test-Admin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-RegValue {
    param([string]$Path, [string]$Name)

    try {
        return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
    } catch {
        return $null
    }
}

function Set-Dword {
    param([string]$Path, [string]$Name, [int]$Value)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Get-ServiceState {
    param([string]$Name)

    if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
        return 'n/a'
    }
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        return 'missing'
    }
    return ('{0}/{1}' -f $service.Status, $service.StartType)
}

function Test-OneDriveInstalled {
    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe')
    }
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe')
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $true
        }
    }
    return $false
}

function Save-OneDriveRun {
    if (Test-Path -LiteralPath $oneDriveState) {
        return
    }
    $command = Get-RegValue -Path $oneDriveRun -Name 'OneDrive'
    if (-not $command) {
        return
    }
    try {
        if (-not (Test-Path -LiteralPath $stateDir)) {
            New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
        }
        [pscustomobject]@{ RunCommand = $command } | ConvertTo-Json |
            Set-Content -LiteralPath $oneDriveState -Encoding UTF8
    } catch {
        Write-Warning ("Could not save the OneDrive startup command: {0}" -f $_.Exception.Message)
    }
}

function Disable-OneDrive {
    param([switch]$Quiet)

    if ($DryRun) {
        Write-Host 'Dry run: would disable the OneDrive policy, startup entry and OneDrive tasks.' -ForegroundColor Yellow
        return
    }

    Write-Host 'Disabling OneDrive sync and startup ...'
    Set-Dword $oneDrivePolicy 'DisableFileSyncNGSC' 1
    Save-OneDriveRun

    Get-Process -Name OneDrive, FileCoAuth -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $oneDriveRun) {
        Remove-ItemProperty -Path $oneDriveRun -Name 'OneDrive' -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $oneDriveRun -Name 'OneDriveSetup' -Force -ErrorAction SilentlyContinue
    }

    Get-ScheduledTask -TaskPath '\Microsoft\Windows\OneDrive\*' -ErrorAction SilentlyContinue |
        ForEach-Object {
            try {
                Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction Stop | Out-Null
            } catch {
                Write-Warning ("Could not disable task {0}: {1}" -f $_.TaskName, $_.Exception.Message)
            }
        }

    if (-not $Quiet) {
        Write-Host 'OneDrive policy is disabled; files and folders are untouched.' -ForegroundColor Green
        Write-Host 'Re-enable with -RestoreOneDrive.'
    }
}

function Remove-OneDrive {
    param([switch]$Quiet)

    Disable-OneDrive -Quiet:$Quiet
    if ($DryRun) {
        Write-Host 'Dry run: would run OneDriveSetup.exe /uninstall and remove Microsoft.OneDriveSync.' -ForegroundColor Yellow
        return
    }

    $setupPaths = @(
        (Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'),
        (Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe')
    )
    $removed = $false
    foreach ($setup in $setupPaths) {
        if ($setup -and (Test-Path -LiteralPath $setup)) {
            Write-Host ("Running {0} /uninstall ..." -f $setup)
            try {
                $process = Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait -PassThru -ErrorAction Stop
                if ($process.ExitCode -eq 0) {
                    $removed = $true
                } else {
                    Write-Warning ("OneDriveSetup exited with {0}" -f $process.ExitCode)
                }
            } catch {
                Write-Warning ("OneDrive uninstall failed: {0}" -f $_.Exception.Message)
            }
        }
    }
    if (-not $removed) {
        Write-Host 'OneDriveSetup.exe was not found; removing the packaged bridge only.' -ForegroundColor Yellow
    }

    Remove-StockApps -Patterns @('Microsoft.OneDriveSync') -Quiet:$Quiet
    Write-Host 'OneDrive removal requested; local OneDrive files are left in place.' -ForegroundColor Green
    Write-Host 'It can be reinstalled from https://www.microsoft.com/microsoft-365/onedrive/download.'
}

function Restore-OneDrive {
    if ($DryRun) {
        Write-Host 'Dry run: would re-enable the OneDrive policy and start OneDrive.' -ForegroundColor Yellow
        return
    }

    Write-Host 'Re-enabling OneDrive policy ...'
    Set-Dword $oneDrivePolicy 'DisableFileSyncNGSC' 0

    if (Test-Path -LiteralPath $oneDriveState) {
        try {
            $saved = Get-Content -LiteralPath $oneDriveState -Raw | ConvertFrom-Json
            if ($saved.RunCommand) {
                New-ItemProperty -Path $oneDriveRun -Name 'OneDrive' -Value $saved.RunCommand `
                    -PropertyType String -Force | Out-Null
            }
        } catch {
            Write-Warning ("Could not restore the OneDrive startup command: {0}" -f $_.Exception.Message)
        }
    }

    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe')
    }
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe')
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            Start-Process -FilePath $candidate -ArgumentList '/background' -ErrorAction SilentlyContinue
            break
        }
    }
    Write-Host 'OneDrive policy is enabled. Reinstall it first if it was uninstalled.' -ForegroundColor Green
}

function Get-StockAppMatches {
    param([string[]]$Patterns)

    $allInstalled = @()
    $allProvisioned = @()
    $installed = @()
    $provisioned = @()

    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        $allInstalled = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    }
    if (Get-Command Get-AppxProvisionedPackage -ErrorAction SilentlyContinue) {
        $allProvisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
    }

    foreach ($pattern in $Patterns) {
        $installed += @($allInstalled | Where-Object { $_.Name -like "$pattern*" })
        $provisioned += @($allProvisioned | Where-Object { $_.PackageName -like "$pattern*" })
    }

    return [pscustomobject]@{
        Installed = @($installed | Sort-Object Name -Unique)
        Provisioned = @($provisioned | Sort-Object PackageName -Unique)
    }
}

function Remove-StockApps {
    param(
        [string[]]$Patterns,
        [switch]$Quiet
    )

    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) -or
        -not (Get-Command Get-AppxProvisionedPackage -ErrorAction SilentlyContinue)) {
        Write-Warning 'AppX cmdlets are not available on this system.'
        return
    }

    $allInstalled = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    $allProvisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
    $installedRemoved = 0
    $provisionedRemoved = 0

    foreach ($pattern in $Patterns) {
        $provisioned = @($allProvisioned | Where-Object { $_.PackageName -like "$pattern*" })
        foreach ($package in $provisioned) {
            if ($DryRun) {
                Write-Host ("would remove provisioned: {0}" -f $package.PackageName)
                continue
            }
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop | Out-Null
                $provisionedRemoved++
            } catch {
                Write-Warning ("provisioned failed: {0}: {1}" -f $package.PackageName, $_.Exception.Message)
            }
        }

        $installed = @($allInstalled | Where-Object { $_.Name -like "$pattern*" })
        foreach ($package in $installed) {
            if ($DryRun) {
                Write-Host ("would remove installed: {0}" -f $package.PackageFullName)
                continue
            }
            try {
                Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
                $installedRemoved++
            } catch {
                Write-Warning ("installed failed: {0}: {1}" -f $package.Name, $_.Exception.Message)
            }
        }
    }

    if (-not $Quiet) {
        if ($DryRun) {
            Write-Host 'Dry run: no apps were removed.' -ForegroundColor Yellow
        } else {
            Write-Host ("Removed {0} provisioned and {1} installed package(s)." -f $provisionedRemoved, $installedRemoved) -ForegroundColor Green
        }
    }
}

function Test-AccessDenied {
    param($ErrorRecord)

    if (-not $ErrorRecord) {
        return $false
    }
    $inner = $ErrorRecord.Exception.InnerException
    if ($inner -and $inner.NativeErrorCode -eq 5) {
        return $true
    }
    return [bool]($ErrorRecord.Exception.Message -match 'Zugriff verweigert|Access is denied|Access denied|0x5')
}

function Disable-StockServices {
    param(
        [object[]]$Entries,
        [switch]$Quiet
    )

    if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
        Write-Warning 'The service cmdlets are not available on this system.'
        return
    }

    $saved = @()
    if (Test-Path -LiteralPath $serviceState) {
        try {
            $saved = @(Get-Content -LiteralPath $serviceState -Raw | ConvertFrom-Json)
        } catch {
            Write-Warning 'Could not read the service backup; starting a new one.'
        }
    }

    $seen = @{}
    foreach ($entry in $saved) {
        $seen[$entry.Name] = $true
    }

    $changed = 0
    $skipped = 0
    foreach ($entry in $Entries) {
        $service = Get-Service -Name $entry.Name -ErrorAction SilentlyContinue
        if (-not $service) {
            continue
        }

        if (-not $seen.ContainsKey($entry.Name) -and [string]$service.StartType -ne 'Disabled') {
            $saved += [pscustomobject]@{ Name = $entry.Name; StartType = [string]$service.StartType }
            $seen[$entry.Name] = $true
        }

        if ($DryRun) {
            Write-Host ("would set {0} to {1}" -f $entry.Name, $entry.Type)
            continue
        }

        try {
            $didChange = $false
            if ([string]$service.StartType -ne $entry.Type) {
                Set-Service -Name $entry.Name -StartupType $entry.Type -ErrorAction Stop
                $didChange = $true
            }
            if ($entry.Type -eq 'Disabled') {
                Stop-Service -Name $entry.Name -Force -ErrorAction SilentlyContinue
            }
            if ($didChange) {
                $changed++
            }
        } catch {
            if (Test-AccessDenied $_) {
                Write-Host ("    skipped (protected): {0}" -f $entry.Name) -ForegroundColor Yellow
                $skipped++
            } else {
                Write-Warning ("service failed: {0}: {1}" -f $entry.Name, $_.Exception.Message)
            }
        }
    }

    if (-not $DryRun -and $saved.Count -gt 0) {
        try {
            if (-not (Test-Path -LiteralPath $stateDir)) {
                New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
            }
            $saved | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $serviceState -Encoding UTF8
        } catch {
            Write-Warning ("Could not save service state: {0}" -f $_.Exception.Message)
        }
    }

    if (-not $Quiet) {
        if ($DryRun) {
            Write-Host 'Dry run: no services were changed.' -ForegroundColor Yellow
        } else {
            Write-Host ("Changed {0} service(s); skipped {1} protected." -f $changed, $skipped) -ForegroundColor Green
            Write-Host 'Restore with -RestoreServices.'
        }
    }
}

function Restore-StockServices {
    if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
        Write-Warning 'The service cmdlets are not available on this system.'
        return
    }
    if (-not (Test-Path -LiteralPath $serviceState)) {
        Write-Host 'No service backup found.' -ForegroundColor Yellow
        return
    }

    $saved = @(Get-Content -LiteralPath $serviceState -Raw | ConvertFrom-Json)
    foreach ($entry in $saved) {
        $service = Get-Service -Name $entry.Name -ErrorAction SilentlyContinue
        if (-not $service) {
            continue
        }
        try {
            Set-Service -Name $entry.Name -StartupType $entry.StartType -ErrorAction Stop
            Write-Host ("restored {0} to {1}" -f $entry.Name, $entry.StartType)
        } catch {
            Write-Warning ("restore failed: {0}: {1}" -f $entry.Name, $_.Exception.Message)
        }
    }
    Write-Host 'Service startup types restored. Reboot to apply.' -ForegroundColor Green
}

function Show-StockStatus {
    $policy = Get-RegValue -Path $oneDrivePolicy -Name 'DisableFileSyncNGSC'
    $policyText = if ($policy -eq 1) { 'yes' } elseif ($null -eq $policy) { 'not set' } else { 'no' }

    Write-Host 'OneDrive' -ForegroundColor Cyan
    Write-Host ("  policy disabled : {0}" -f $policyText)
    Write-Host ("  installed       : {0}" -f (Test-OneDriveInstalled))
    Write-Host ("  running         : {0}" -f [bool](Get-Process -Name OneDrive -ErrorAction SilentlyContinue))
    Write-Host ("  Run entry       : {0}" -f [bool](Get-RegValue -Path $oneDriveRun -Name 'OneDrive'))

    Write-Host ''
    Write-Host 'Stock apps' -ForegroundColor Cyan
    $lean = Get-StockAppMatches -Patterns $leanApps
    Write-Host ("  lean matches      : {0} installed, {1} provisioned" -f $lean.Installed.Count, $lean.Provisioned.Count)
    $aggressive = Get-StockAppMatches -Patterns $aggressiveApps
    Write-Host ("  aggressive matches: {0} installed, {1} provisioned" -f $aggressive.Installed.Count, $aggressive.Provisioned.Count)
    if ($lean.Installed.Count -gt 0) {
        $lean.Installed | Select-Object -First 8 Name | Format-Table -AutoSize
    }

    Write-Host 'Stock services' -ForegroundColor Cyan
    $allServices = @($leanServices + $balancedServices + $aggressiveServices | Sort-Object Name -Unique)
    $allServices |
        Select-Object Name, Label, @{n='State';e={Get-ServiceState -Name $_.Name}} |
        Format-Table -AutoSize
}

function Confirm-Action {
    param([string]$Question)

    $answer = Read-Host ("{0} [y/N]" -f $Question)
    return @('y', 'yes', 'j', 'ja') -contains $answer.Trim().ToLowerInvariant()
}

function Pause-Menu {
    [void](Read-Host 'Press Enter to continue')
}

function Show-Menu {
    Write-Host ''
    Write-Host 'Stock apps, OneDrive and services' -ForegroundColor Cyan
    Write-Host ('-' * 64)
    Write-Host '   1) Show OneDrive, stock apps and service status'
    Write-Host '   2) OneDrive: disable sync and startup (keeps files)'
    Write-Host '   3) OneDrive: uninstall'
    Write-Host '   4) Remove lean stock apps'
    Write-Host '   5) Remove aggressive stock apps (includes Store)'
    Write-Host '   6) Disable lean stock services'
    Write-Host '   7) Disable aggressive stock services'
    Write-Host '   8) Restore service startup types'
    Write-Host '   9) Restore OneDrive policy and start it'
    Write-Host '  10) Open Windows Apps settings'
    Write-Host '   R) Recommended: disable OneDrive, lean apps, lean services'
    Write-Host '   0) Back'
    Write-Host ''
}

function Invoke-Recommended {
    Disable-OneDrive
    Remove-StockApps -Patterns $leanApps
    Disable-StockServices -Entries $leanServices
}

if ($List) {
    Show-StockStatus
    return
}

if ($RestoreServices) {
    Restore-StockServices
    return
}

if ($RestoreOneDrive) {
    Restore-OneDrive
    return
}

if ($OneDrive -ne 'None' -or $Apps -ne 'None' -or $Services -ne 'None') {
    if (-not (Test-Admin)) {
        Write-Warning 'Running without elevation; service and package changes will fail.'
    }
    if ($OneDrive -eq 'Disable') { Disable-OneDrive }
    if ($OneDrive -eq 'Remove') { Remove-OneDrive }
    if ($Apps -eq 'Lean') { Remove-StockApps -Patterns $leanApps }
    if ($Apps -eq 'Aggressive') { Remove-StockApps -Patterns $aggressiveApps }
    if ($Services -eq 'Lean') { Disable-StockServices -Entries $leanServices }
    if ($Services -eq 'Balanced') { Disable-StockServices -Entries $balancedServices }
    if ($Services -eq 'Aggressive') { Disable-StockServices -Entries $aggressiveServices }
    return
}

if (-not (Test-Admin)) {
    Write-Warning 'Not elevated. Close this and run helper.bat or trim-stock.bat.'
}

while ($true) {
    Show-Menu
    try {
        $choice = Read-Host 'Select'
    } catch {
        return
    }
    if ([string]::IsNullOrWhiteSpace($choice)) {
        continue
    }
    $choice = $choice.Trim()

    switch ($choice) {
        '1' {
            Show-StockStatus
            Pause-Menu
        }
        '2' {
            if (Confirm-Action 'Disable OneDrive sync and startup? Files are kept') {
                Disable-OneDrive
                Pause-Menu
            }
        }
        '3' {
            if (Confirm-Action 'Uninstall OneDrive? Local OneDrive files are kept, but the client is removed') {
                Remove-OneDrive
                Pause-Menu
            }
        }
        '4' {
            if (Confirm-Action 'Remove the lean list of stock apps') {
                Remove-StockApps -Patterns $leanApps
                Pause-Menu
            }
        }
        '5' {
            if (Confirm-Action 'Remove the aggressive list, including Microsoft Store') {
                Remove-StockApps -Patterns $aggressiveApps
                Pause-Menu
            }
        }
        '6' {
            if (Confirm-Action 'Disable the lean list of stock services') {
                Disable-StockServices -Entries $leanServices
                Pause-Menu
            }
        }
        '7' {
            if (Confirm-Action 'Disable the aggressive list, including Search and SysMain') {
                Disable-StockServices -Entries $aggressiveServices
                Pause-Menu
            }
        }
        '8' {
            if (Confirm-Action 'Restore the saved service startup types') {
                Restore-StockServices
                Pause-Menu
            }
        }
        '9' {
            if (Confirm-Action 'Restore the OneDrive policy and start OneDrive') {
                Restore-OneDrive
                Pause-Menu
            }
        }
        '10' {
            try {
                Start-Process -FilePath 'ms-settings:appsfeatures' -ErrorAction Stop
            } catch {
                Write-Host ("Could not open Apps settings: {0}" -f $_.Exception.Message) -ForegroundColor Red
                Pause-Menu
            }
        }
        'r' {
            if (Confirm-Action 'Disable OneDrive, remove lean stock apps and disable lean services') {
                Invoke-Recommended
                Pause-Menu
            }
        }
        '0' {
            return
        }
        default {
            Write-Host 'Unknown choice.' -ForegroundColor Yellow
            Start-Sleep -Milliseconds 700
        }
    }
}