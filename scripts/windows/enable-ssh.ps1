# Install and enable the Windows OpenSSH Server for terminal-only access.
#
# The default action enables sshd, opens TCP 22, sets PowerShell as the default
# shell and keeps password authentication enabled. Pass -PublicKeyPath to
# install an authorized key; add -DisablePasswordAuthentication afterwards.
#
# From the Mac (through the NixOS host):
#   ./scripts/win-ssh.sh
# or:
#   ssh -J nixos@192.168.178.5 Windows-PC@192.168.122.50

[CmdletBinding()]
param(
    [switch]$Disable,
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$DisablePasswordAuthentication,
    [string]$PublicKeyPath,
    [string]$User = $env:USERNAME
)

$ErrorActionPreference = 'Continue'
$capability = 'OpenSSH.Server~~~~0.0.1.0'
$programData = if ($env:ProgramData) { $env:ProgramData } else { [IO.Path]::GetTempPath() }
$sshdConfig = Join-Path $programData 'ssh\sshd_config'
$firewallRule = 'OpenSSH-Server-In-TCP'

function Test-Admin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-SshdOption {
    param([string]$Name)

    if (-not (Test-Path -LiteralPath $sshdConfig)) {
        return $null
    }
    $line = Get-Content -LiteralPath $sshdConfig -ErrorAction SilentlyContinue |
        Where-Object { $_ -match ('^\s*' + [regex]::Escape($Name) + '\s+') } |
        Select-Object -First 1
    if (-not $line) {
        return $null
    }
    return ($line -split '\s+', 2)[1]
}

function Set-SshdOption {
    param([string]$Name, [string]$Value)

    if (-not (Test-Path -LiteralPath $sshdConfig)) {
        throw "sshd_config not found: $sshdConfig"
    }

    $backup = "$sshdConfig.bak"
    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $sshdConfig -Destination $backup -Force
    }

    $lines = @(Get-Content -LiteralPath $sshdConfig)
    $pattern = '^\s*#?\s*' + [regex]::Escape($Name) + '\s+'
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) {
            $lines[$i] = "$Name $Value"
            $found = $true
        }
    }
    if (-not $found) {
        $lines += "$Name $Value"
    }
    Set-Content -LiteralPath $sshdConfig -Value $lines -Encoding ASCII
}

function Install-PublicKey {
    param([string]$Path, [string]$UserName)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning ("Public key not found: {0}" -f $Path)
        return $false
    }

    $key = (Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not $key -or $key -notmatch '^(ssh-|ecdsa-|sk-)') {
        Write-Warning 'That does not look like an OpenSSH public key.'
        return $false
    }

    $isAdmin = $false
    try {
        $adminGroup = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
        $members = Get-LocalGroupMember -Group $adminGroup.Name -ErrorAction Stop
        $isAdmin = [bool]($members | Where-Object {
            $_.Name -eq $UserName -or $_.Name -match ('\\' + [regex]::Escape($UserName) + '$')
        })
    } catch {
        Write-Warning 'Could not determine group membership; writing the user key file.'
    }

    if ($isAdmin) {
        $file = Join-Path $programData 'ssh\administrators_authorized_keys'
    } else {
        $file = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
    }

    $directory = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $existing = @()
    if (Test-Path -LiteralPath $file) {
        $existing = @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)
    }
    if ($existing -notcontains $key) {
        Add-Content -LiteralPath $file -Value $key
    }

    if ($isAdmin) {
        & icacls.exe $file /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
    } else {
        & icacls.exe $file /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
    }

    Write-Host ("Authorized key installed for {0} in {1}" -f $UserName, $file) -ForegroundColor Green
    return $true
}

function Show-SshStatus {
    Write-Host 'SSH status' -ForegroundColor Cyan
    Write-Host ('-' * 64)

    if (Get-Command Get-WindowsCapability -ErrorAction SilentlyContinue) {
        $cap = Get-WindowsCapability -Online -Name $capability -ErrorAction SilentlyContinue
        if ($cap) {
            Write-Host ("OpenSSH.Server : {0}" -f $cap.State)
        }
    }

    $service = $null
    if (Get-Command Get-Service -ErrorAction SilentlyContinue) {
        $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    }
    if ($service) {
        Write-Host ("sshd service   : {0}/{1}" -f $service.Status, $service.StartType)
    } else {
        Write-Host 'sshd service   : missing'
    }

    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $listener = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue
        Write-Host ("port 22        : {0}" -f $(if ($listener) { 'listening' } else { 'not listening' }))
    }

    $rule = $null
    if (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) {
        $rule = Get-NetFirewallRule -Name $firewallRule -ErrorAction SilentlyContinue
    }
    if ($rule) {
        Write-Host ("firewall rule  : {0}" -f $rule.Enabled)
    } else {
        Write-Host 'firewall rule  : missing'
    }

    $defaultShell = $null
    try {
        $defaultShell = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction Stop).DefaultShell
    } catch {
        $defaultShell = $null
    }
    Write-Host ("default shell  : {0}" -f $defaultShell)
    Write-Host ("password auth  : {0}" -f (Get-SshdOption -Name 'PasswordAuthentication'))
    Write-Host ("pubkey auth    : {0}" -f (Get-SshdOption -Name 'PubkeyAuthentication'))
    Write-Host ("admin keys     : {0}" -f (Test-Path -LiteralPath (Join-Path $programData 'ssh\administrators_authorized_keys')))
    $userKeys = $false
    if ($env:USERPROFILE) {
        $userKeys = Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.ssh\authorized_keys')
    }
    Write-Host ("user keys      : {0}" -f $userKeys)
}

function Show-ConnectionInfo {
    Write-Host ''
    Write-Host 'From the Mac:' -ForegroundColor Yellow
    Write-Host ('  ssh -J nixos@192.168.178.5 {0}@192.168.122.50' -f $User)
    Write-Host '  ./scripts/win-ssh.sh'
    Write-Host ''
    Write-Host 'The guest IP is the libvirt lease; verify it on the host with:'
    Write-Host '  sudo virsh domifaddr win11-stock --source lease'
}

function Enable-Ssh {
    if (-not (Test-Admin)) {
        Write-Warning 'OpenSSH setup needs an elevated shell. Run enable-ssh.bat or helper.bat.'
        return
    }

    Write-Host 'Installing and enabling OpenSSH Server ...'
    if (-not (Get-Command Get-WindowsCapability -ErrorAction SilentlyContinue)) {
        Write-Warning 'Get-WindowsCapability is not available on this build.'
        return
    }

    $cap = Get-WindowsCapability -Online -Name $capability -ErrorAction SilentlyContinue
    if (-not $cap) {
        Write-Warning ("Capability not found: {0}" -f $capability)
        return
    }
    if ($cap.State -ne 'Installed') {
        Write-Host ("Installing {0} ..." -f $capability)
        Add-WindowsCapability -Online -Name $capability -ErrorAction SilentlyContinue | Out-Null
        $cap = Get-WindowsCapability -Online -Name $capability -ErrorAction SilentlyContinue
        if (-not $cap -or $cap.State -ne 'Installed') {
            Write-Warning 'OpenSSH Server could not be installed. Check Windows Update or add it with DISM.'
            return
        }
    }

    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Warning 'The sshd service is missing after installation.'
        return
    }

    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd
    Write-Host 'sshd started.' -ForegroundColor Green

    $rule = Get-NetFirewallRule -Name $firewallRule -ErrorAction SilentlyContinue
    if ($rule) {
        Enable-NetFirewallRule -Name $firewallRule -ErrorAction SilentlyContinue
    } else {
        New-NetFirewallRule -Name $firewallRule -DisplayName 'OpenSSH Server (sshd)' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Any | Out-Null
    }

    $openSshKey = 'HKLM:\SOFTWARE\OpenSSH'
    if (-not (Test-Path -LiteralPath $openSshKey)) {
        New-Item -Path $openSshKey -Force | Out-Null
    }
    New-ItemProperty -Path $openSshKey -Name DefaultShell `
        -Value "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -PropertyType String -Force | Out-Null

    $keyInstalled = $false
    if ($PublicKeyPath) {
        $keyInstalled = Install-PublicKey -Path $PublicKeyPath -UserName $User
    }

    if (Test-Path -LiteralPath $sshdConfig) {
        Set-SshdOption -Name 'PubkeyAuthentication' -Value 'yes'
        if ($DisablePasswordAuthentication -and $keyInstalled) {
            Set-SshdOption -Name 'PasswordAuthentication' -Value 'no'
        } else {
            Set-SshdOption -Name 'PasswordAuthentication' -Value 'yes'
            if ($DisablePasswordAuthentication) {
                Write-Warning 'No key was installed; password authentication stays enabled.'
            }
        }
    } else {
        Write-Warning ("sshd_config not found: {0}" -f $sshdConfig)
    }

    Restart-Service -Name sshd -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Show-SshStatus
    Show-ConnectionInfo
}

function Disable-Ssh {
    if (-not (Test-Admin)) {
        Write-Warning 'This needs an elevated shell.'
        return
    }

    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($service) {
        Stop-Service -Name sshd -Force -ErrorAction SilentlyContinue
        Set-Service -Name sshd -StartupType Disabled
    }
    Disable-NetFirewallRule -Name $firewallRule -ErrorAction SilentlyContinue
    Write-Host 'SSH server disabled; OpenSSH remains installed.' -ForegroundColor Green
}

function Uninstall-Ssh {
    if (-not (Test-Admin)) {
        Write-Warning 'This needs an elevated shell.'
        return
    }

    Disable-Ssh
    if (Get-Command Remove-WindowsCapability -ErrorAction SilentlyContinue) {
        Write-Host 'Removing the OpenSSH Server capability ...'
        Remove-WindowsCapability -Online -Name $capability -ErrorAction SilentlyContinue | Out-Null
    }
    Remove-NetFirewallRule -Name $firewallRule -ErrorAction SilentlyContinue
    Write-Host 'OpenSSH Server removed. The sshd_config backup is left in place.' -ForegroundColor Green
}

if ($Status) {
    Show-SshStatus
    Show-ConnectionInfo
    return
}

if ($Uninstall) {
    Uninstall-Ssh
    return
}

if ($Disable) {
    Disable-Ssh
    return
}

Enable-Ssh