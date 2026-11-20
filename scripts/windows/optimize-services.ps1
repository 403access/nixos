# Trim Windows services that are irrelevant on a desktop VM.
#
# Only services with no effect on boot, networking, audio, printing, Defender
# or Windows Update are touched.  Use -IncludeSearch and -IncludeSysMain for
# the two services that trade indexing/prefetch for lower idle load.

[CmdletBinding()]
param(
    [switch]$IncludeSearch,
    [switch]$IncludeSysMain
)

$ErrorActionPreference = 'Continue'

function Set-ServiceState {
    param(
        [string]$Name,
        [string]$Label,
        [string]$StartupType
    )

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Host "    not present: $Label ($Name)"
        return
    }

    try {
        $current = (Get-Service -Name $Name).StartType
        if ([string]$current -ne $StartupType) {
            Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        }
        if ($StartupType -eq 'Disabled') {
            Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        }
        Write-Host "    $($StartupType.ToLower()): $Label ($Name)"
    } catch {
        Write-Warning "    failed: $Label ($Name): $($_.Exception.Message)"
    }
}

Write-Host 'Disabling unused services ...'
Set-ServiceState -Name MapsBroker    -Label 'Downloaded Maps Manager'           -StartupType Disabled
Set-ServiceState -Name Fax           -Label 'Fax'                               -StartupType Disabled
Set-ServiceState -Name RemoteRegistry -Label 'Remote Registry'                  -StartupType Disabled
Set-ServiceState -Name RetailDemo    -Label 'Retail Demo'                       -StartupType Disabled
Set-ServiceState -Name WMPNetworkSvc -Label 'Windows Media Player sharing'      -StartupType Disabled
Set-ServiceState -Name Spooler       -Label 'Print Spooler'                     -StartupType Disabled
Set-ServiceState -Name PrintWorkflowUserSvc -Label 'Print Workflow'             -StartupType Disabled
Set-ServiceState -Name PrintScanBrokerService -Label 'Print Scan Broker'        -StartupType Disabled
Set-ServiceState -Name PrintDeviceConfigurationService -Label 'Print Device Config' -StartupType Disabled
Set-ServiceState -Name PrintNotify   -Label 'Print Notification'                -StartupType Disabled

Write-Host 'Switching occasional services to manual ...'
Set-ServiceState -Name PcaSvc    -Label 'Program Compatibility Assistant' -StartupType Manual
Set-ServiceState -Name WpcMonSvc -Label 'Parental Controls'              -StartupType Manual
Set-ServiceState -Name PhoneSvc  -Label 'Phone Service (Phone Link)'     -StartupType Manual

if ($IncludeSearch) {
    Write-Host 'Disabling Windows Search indexing ...'
    Set-ServiceState -Name WSearch -Label 'Windows Search' -StartupType Disabled
}

if ($IncludeSysMain) {
    Write-Host 'Disabling SysMain (Superfetch) ...'
    Set-ServiceState -Name SysMain -Label 'SysMain' -StartupType Disabled
}

Write-Host ''
Write-Host 'Kept enabled: Defender, Windows Update, BITS, Event Log, RPC, audio.'
Write-Host 'Printing is disabled with the Print Spooler; re-enable Spooler if needed.'
if (-not $IncludeSearch) {
    Write-Host 'Search indexing still runs; use -IncludeSearch to disable it.'
}
if (-not $IncludeSysMain) {
    Write-Host 'SysMain still runs; use -IncludeSysMain to disable it.'
}