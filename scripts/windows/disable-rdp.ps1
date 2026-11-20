# Disable Remote Desktop and remove the explicit RDP firewall rule.
#
# The TermService service is deliberately left running, because stopping it
# would disconnect an active RDP session. New connections are refused by the
# fDenyTSConnections policy value.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

Write-Host 'Disabling Remote Desktop ...'
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
    -Name fDenyTSConnections -Value 1 -Type DWord

$rule = Get-NetFirewallRule -DisplayName 'RDP 3389' -ErrorAction SilentlyContinue
if ($rule) {
    $rule | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Write-Host 'Removed the "RDP 3389" firewall rule.'
} else {
    Write-Host 'No "RDP 3389" firewall rule found.'
}

Write-Host ''
Write-Host 'Remote Desktop is disabled; TermService was left running.'
Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
    -Name fDenyTSConnections | Select-Object fDenyTSConnections | Format-List