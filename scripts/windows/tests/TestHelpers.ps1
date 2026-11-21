# Shared helpers for the cross-platform Pester suite.
#
# Windows-only cmdlets do not exist on macOS/Linux.  Pester can only mock a
# command that exists, so define inert stubs first.  The stubs are only created
# when the real cmdlet is unavailable.

function Initialize-WindowsCmdletStubs {
    if (-not (Get-Command -Name Get-Service -ErrorAction SilentlyContinue)) {
        function global:Get-Service {
            [CmdletBinding()]
            param([string]$Name)
        }
    }
    if (-not (Get-Command -Name Set-Service -ErrorAction SilentlyContinue)) {
        function global:Set-Service {
            [CmdletBinding()]
            param([string]$Name, [string]$StartupType)
        }
    }
    if (-not (Get-Command -Name Start-Service -ErrorAction SilentlyContinue)) {
        function global:Start-Service {
            [CmdletBinding()]
            param([string]$Name)
        }
    }
    if (-not (Get-Command -Name Stop-Service -ErrorAction SilentlyContinue)) {
        function global:Stop-Service {
            [CmdletBinding()]
            param([string]$Name, [switch]$Force)
        }
    }
    if (-not (Get-Command -Name Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
        function global:Get-MpComputerStatus {
            [CmdletBinding()]
            param()
        }
    }
    if (-not (Get-Command -Name Get-MpPreference -ErrorAction SilentlyContinue)) {
        function global:Get-MpPreference {
            [CmdletBinding()]
            param()
        }
    }
    if (-not (Get-Command -Name Set-MpPreference -ErrorAction SilentlyContinue)) {
        function global:Set-MpPreference {
            [CmdletBinding()]
            param(
                [bool]$DisableRealtimeMonitoring,
                [bool]$DisableBehaviorMonitoring,
                [bool]$DisableScriptScanning,
                [bool]$DisableIOAVProtection
            )
        }
    }
    if (-not (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue)) {
        function global:Get-CimInstance {
            [CmdletBinding()]
            param(
                [string]$Namespace,
                [string]$ClassName
            )
        }
    }
}