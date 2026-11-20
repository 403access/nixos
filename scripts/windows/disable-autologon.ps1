$ErrorActionPreference = 'Stop'
$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

Set-ItemProperty $key -Name AutoAdminLogon -Value '0' -Type String
Remove-ItemProperty $key -Name DefaultPassword -ErrorAction SilentlyContinue

Write-Host 'Automatic logon disabled.'
Get-ItemProperty $key |
    Select-Object AutoAdminLogon, DefaultUserName, DefaultDomainName |
    Format-List