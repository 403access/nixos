$ErrorActionPreference = 'Continue'
Write-Host '== Computer =='; hostname
Write-Host '== Local users =='; Get-LocalUser | Select-Object Name,Enabled | Format-Table -AutoSize

Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0

New-NetFirewallRule -DisplayName 'RDP 3389' -Direction Inbound -Protocol TCP `
  -LocalPort 3389 -Action Allow -Profile Any -ErrorAction SilentlyContinue

Get-NetConnectionProfile | ForEach-Object {
  Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
}

$v = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Host ("Edition: " + $v.ProductName + " / " + $v.EditionID)

Get-NetFirewallRule -DisplayName 'RDP 3389' | Format-Table DisplayName,Enabled,Direction,Action
netstat -an | Select-String ':3389'
Write-Host 'Done.'
