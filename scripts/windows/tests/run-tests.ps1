# Run the cross-platform Pester suite for the Windows helper scripts.
#
#   pwsh -NoProfile -File scripts/windows/tests/run-tests.ps1
#
# Pester 5 or newer is required.  If it is missing, the script installs it into
# the current user scope (CI does the same).

[CmdletBinding()]
param(
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable Pester)) {
    if ($SkipInstall) {
        Write-Error 'Pester is not installed. Install-Module Pester -Scope CurrentUser'
        exit 2
    }
    Write-Host 'Installing Pester into the current user scope ...'
    try {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
    } catch {
        # The repository may already be trusted or unavailable; Install-Module
        # reports the useful error next.
    }
    Install-Module -Name Pester -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop
}

Import-Module Pester -MinimumVersion 5.0

$result = Invoke-Pester -Path $PSScriptRoot -Output Detailed -PassThru
if ($result.FailedCount -gt 0) {
    Write-Host ("{0} Pester test(s) failed." -f $result.FailedCount) -ForegroundColor Red
    exit 1
}

Write-Host ("All {0} Pester tests passed." -f $result.PassedCount) -ForegroundColor Green