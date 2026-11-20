[CmdletBinding()]
param(
    [string]$User = 'Windows-PC'
)

$ErrorActionPreference = 'Stop'
$computer = $env:COMPUTERNAME
$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

if (-not (Get-LocalUser -Name $User -ErrorAction SilentlyContinue)) {
    throw "Local user '$User' does not exist. Pass -User NAME."
}

$secure = Read-Host -AsSecureString "Password for $computer\$User"
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

try {
    Set-ItemProperty $key -Name AutoAdminLogon    -Value '1'          -Type String
    Set-ItemProperty $key -Name DefaultUserName   -Value $User        -Type String
    Set-ItemProperty $key -Name DefaultDomainName -Value $computer    -Type String
    Set-ItemProperty $key -Name DefaultPassword   -Value $plain       -Type String
    Remove-ItemProperty $key -Name AutoLogonCount -ErrorAction SilentlyContinue
} finally {
    $plain = $null
}

Write-Host "Automatic logon enabled for $computer\$User"
Get-ItemProperty $key |
    Select-Object AutoAdminLogon, DefaultUserName, DefaultDomainName |
    Format-List
Write-Host ''
Write-Host 'The password is stored in the Winlogon registry key. Use a strong'
Write-Host 'password and keep the guest behind loopback, SSH or Tailscale.'
Write-Host 'Run disable-autologon.bat to revert.'