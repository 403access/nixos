$ErrorActionPreference = 'Continue'
Write-Host '== Computer =='; hostname
Write-Host '== Local users =='; Get-LocalUser | Select-Object Name,Enabled | Format-Table -AutoSize

Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0

Write-Host 'Starting TermService ...'
Set-Service -Name TermService -StartupType Automatic
Start-Service -Name TermService

Get-NetFirewallRule -DisplayName 'RDP 3389' -ErrorAction SilentlyContinue |
  Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'RDP 3389' -Direction Inbound -Protocol TCP `
  -LocalPort 3389 -Action Allow -Profile Any | Out-Null

Get-NetConnectionProfile | ForEach-Object {
  Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
}

$v = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Host ("Edition: " + $v.ProductName + " / " + $v.EditionID)

Get-Service TermService | Format-List Name,Status,StartType
Get-NetFirewallRule -DisplayName 'RDP 3389' | Format-Table DisplayName,Enabled,Profile,Action
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object InterfaceAlias -Like 'Ethernet*' |
  Format-Table InterfaceAlias,IPAddress,PrefixLength
netstat -an | Select-String ':3389'
Write-Host 'Done.'