# Interactive main menu for the Windows helper CD.
#
# Double-click helper.bat in Windows. It self-elevates and starts this menu,
# which runs the other scripts in this folder in-process. Nothing is applied
# until an action is chosen and, for the disruptive actions, confirmed.

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\WindowsSlim\windows-helper-menu.log"
)

$ErrorActionPreference = 'Continue'
$scriptRoot = $PSScriptRoot
$running = $true
$script:LastHelperOk = $false

$logDir = Split-Path -Parent $LogPath
try {
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
} catch {
    # Logging is best-effort; the menu must still start.
}

function Test-Admin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Write-Log {
    param([string]$Message)

    try {
        $line = '{0} {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:USERNAME, $Message
        Add-Content -LiteralPath $LogPath -Value $line -ErrorAction Stop
    } catch {
        # The menu must still work when the log path is not writable.
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

function Get-RestorePoints {
    if (-not (Get-Command Get-ComputerRestorePoint -ErrorAction SilentlyContinue)) {
        return @()
    }
    try {
        return @(Get-ComputerRestorePoint -ErrorAction Stop)
    } catch {
        return @()
    }
}

function Get-RdpState {
    $value = Get-RegValue 'HKLM:\System\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections'
    if ($null -eq $value) {
        return 'n/a'
    }
    if ([int]$value -eq 0) {
        return 'on'
    }
    return 'off'
}

function Get-AutologonState {
    $value = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' 'AutoAdminLogon'
    if ($null -eq $value) {
        return 'off'
    }
    if ([string]$value -eq '1') {
        return 'on'
    }
    return 'off'
}

function Get-VisualState {
    $value = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting'
    switch ($value) {
        0 { return 'let Windows choose' }
        1 { return 'best appearance' }
        2 { return 'best performance' }
        3 { return 'custom' }
        default { return 'not set' }
    }
}

function Get-PendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($key in $keys) {
        try {
            if (Test-Path -LiteralPath $key) {
                return 'yes'
            }
        } catch {
            # Registry not available on this platform.
        }
    }
    $renames = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations'
    if ($renames) {
        return 'yes'
    }
    return 'no'
}

function Confirm-Action {
    param([string]$Question)

    $answer = Read-Host ("{0} [y/N]" -f $Question)
    return @('y', 'yes', 'j', 'ja') -contains $answer.Trim().ToLowerInvariant()
}

function Pause-Menu {
    [void](Read-Host 'Press Enter to continue')
}

function Read-MenuChoice {
    param([string]$Menu)

    try {
        $value = Read-Host 'Select'
    } catch {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        return ''
    }
    $value = $value.Trim()
    Write-Log ('menu={0} choice={1}' -f $Menu, $value)
    return $value
}

function Invoke-Helper {
    param(
        [string]$Script,
        [string]$Label,
        [hashtable]$Arguments = @{}
    )

    $path = Join-Path -Path $scriptRoot -ChildPath $Script
    $script:LastHelperOk = $false
    $rendered = @()
    foreach ($key in $Arguments.Keys) {
        if ($Arguments[$key] -eq $true) {
            $rendered += "-$key"
        } else {
            $rendered += ("-{0} {1}" -f $key, $Arguments[$key])
        }
    }
    Write-Log ('run {0} {1}' -f $Script, ($rendered -join ' '))

    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host ('Missing script: {0}' -f $path) -ForegroundColor Red
        return
    }

    Write-Host ''
    Write-Host ('==> {0}' -f $Label) -ForegroundColor Cyan
    Write-Host ''

    try {
        & $path @Arguments
        $script:LastHelperOk = $true
    } catch {
        Write-Host ('Failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
        Write-Log ('error {0}: {1}' -f $Script, $_.Exception.Message)
    }

    Write-Host ''
    if ($script:LastHelperOk) {
        Write-Host 'Finished.' -ForegroundColor Green
    } else {
        Write-Host 'Finished with errors.' -ForegroundColor Yellow
    }
}

function Write-MenuItem {
    param(
        [string]$Key,
        [string]$Text,
        [string]$Note
    )

    Write-Host ('  {0,2}) {1}' -f $Key, $Text)
    if ($Note) {
        Write-Host ('      {0}' -f $Note) -ForegroundColor DarkGray
    }
}

function Show-Header {
    $points = Get-RestorePoints
    $count = if ($points.Count -eq 0) { 'none' } else { [string]$points.Count }
    $admin = if ($isAdmin) { 'yes' } else { 'no' }

    Clear-Host
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ' Windows 11 helper - minimal VM' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host (' {0} | admin: {1} | restore points: {2} | RDP: {3} | autologon: {4}' -f `
        $env:COMPUTERNAME, $admin, $count, (Get-RdpState), (Get-AutologonState))
    if (-not $isAdmin) {
        Write-Host ' WARNING: not elevated. Close this and run helper.bat.' -ForegroundColor Red
    } elseif ($points.Count -eq 0) {
        Write-Host ' Tip: create a restore point before changing anything (main menu 1).' -ForegroundColor Yellow
    }
    Write-Host ''
}

function Show-Dashboard {
    Write-Host 'System dashboard' -ForegroundColor Cyan
    Write-Host ('-' * 64)
    Write-Host ("Computer  : {0}" -f $env:COMPUTERNAME)
    Write-Host ("User      : {0}" -f $env:USERNAME)
    Write-Host ("Elevated  : {0}" -f $isAdmin)
    Write-Host ("Helper    : {0}" -f $scriptRoot)
    Write-Host ("Log       : {0}" -f $LogPath)

    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            Write-Host ("Windows   : {0} (build {1}, {2})" -f $os.Caption, $os.BuildNumber, $os.OSArchitecture)
            if ($os.LastBootUpTime) {
                $uptime = (Get-Date) - $os.LastBootUpTime
                Write-Host ("Uptime    : {0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes)
            }
            Write-Host ("Memory    : {0:N1} GiB total, {1:N1} GiB free" -f `
                ($os.TotalVisibleMemorySize / 1MB), ($os.FreePhysicalMemory / 1MB))
        }
    }

    $drive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
    if ($drive) {
        Write-Host ("Disk C:   : {0:N1} GiB free of {1:N1} GiB" -f `
            ($drive.Free / 1GB), (($drive.Free + $drive.Used) / 1GB))
    }

    Write-Host ''
    Write-Host 'Restore points' -ForegroundColor Yellow
    $points = Get-RestorePoints
    if ($points.Count -eq 0) {
        Write-Host '  none - use main menu 1 to create the first checkpoint.' -ForegroundColor Yellow
    } else {
        $points |
            Sort-Object SequenceNumber -Descending |
            Select-Object SequenceNumber, Description, CreationTime |
            Format-Table -AutoSize
    }

    Write-Host 'Tweak state' -ForegroundColor Yellow
    Write-Host ("  Visual effects : {0}" -f (Get-VisualState))
    Write-Host ("  Telemetry      : {0}" -f (Get-ServiceState 'DiagTrack'))
    Write-Host ("  Search         : {0}" -f (Get-ServiceState 'WSearch'))
    Write-Host ("  SysMain        : {0}" -f (Get-ServiceState 'SysMain'))
    $gameDvr = Get-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled'
    $gameText = if ($null -eq $gameDvr) { 'not set' } elseif ([int]$gameDvr -eq 0) { 'off' } else { 'on' }
    Write-Host ("  Game DVR       : {0}" -f $gameText)
    Write-Host ("  RDP            : {0}" -f (Get-RdpState))
    Write-Host ("  Autologon      : {0}" -f (Get-AutologonState))
    Write-Host ("  Pending reboot : {0}" -f (Get-PendingReboot))

    $explorerAdvanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $hidden = Get-RegValue $explorerAdvanced 'Hidden'
    $fileExt = Get-RegValue $explorerAdvanced 'HideFileExt'
    $launchTo = Get-RegValue $explorerAdvanced 'LaunchTo'
    $hiddenText = if ($hidden -eq 1) { 'shown' } elseif ($hidden -eq 0) { 'hidden' } else { 'not set' }
    $extText = if ($fileExt -eq 0) { 'shown' } elseif ($fileExt -eq 1) { 'hidden' } else { 'not set' }
    $launchText = if ($launchTo -eq 1) { 'This PC' } elseif ($launchTo -eq 2) { 'Home/Quick access' } else { 'not set' }
    Write-Host ("  Hidden files   : {0}" -f $hiddenText)
    Write-Host ("  File extensions: {0}" -f $extText)
    Write-Host ("  Explorer opens : {0}" -f $launchText)

    if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
        Write-Host ''
        Write-Host 'Network' -ForegroundColor Yellow
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '127.*' } |
            Select-Object InterfaceAlias, IPAddress, PrefixLength |
            Format-Table -AutoSize
    }
}

function Show-NetworkInfo {
    Write-Host 'Network and RDP' -ForegroundColor Cyan
    Write-Host ('-' * 64)

    if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '127.*' } |
            Select-Object InterfaceAlias, IPAddress, PrefixLength |
            Format-Table -AutoSize

        Get-NetConnectionProfile -ErrorAction SilentlyContinue |
            Select-Object Name, InterfaceAlias, NetworkCategory |
            Format-Table -AutoSize
    } else {
        Write-Host 'Get-NetIPAddress is not available.'
    }

    Write-Host ("RDP setting : {0}" -f (Get-RdpState))
    if (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) {
        $rule = Get-NetFirewallRule -DisplayName 'RDP 3389' -ErrorAction SilentlyContinue
        if ($rule) {
            $rule | Select-Object DisplayName, Enabled, Profile, Action | Format-Table -AutoSize
        } else {
            Write-Host 'RDP firewall rule: none named "RDP 3389".'
        }
    }
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $listener = Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue
        if ($listener) {
            $listener | Select-Object LocalAddress, LocalPort, State, OwningProcess | Format-Table -AutoSize
        } else {
            Write-Host 'RDP listener: not listening.'
        }
    }
}

function Install-Helper {
    $dest = 'C:\Tools\windows-helper'
    if (-not (Confirm-Action "Copy the helper scripts to $dest and create a desktop shortcut")) {
        return
    }

    try {
        $sourceFull = [IO.Path]::GetFullPath($scriptRoot).TrimEnd([char]'\')
        $destFull = [IO.Path]::GetFullPath($dest).TrimEnd([char]'\')
        if ($sourceFull -ne $destFull) {
            New-Item -Path $dest -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Copy-Item -Path (Join-Path $scriptRoot '*') -Destination $dest -Recurse -Force -ErrorAction Stop
            Write-Host ("Copied to {0}" -f $dest) -ForegroundColor Green
        } else {
            Write-Host ("Already running from {0}" -f $dest) -ForegroundColor Yellow
        }

        $desktop = [Environment]::GetFolderPath('Desktop')
        if ($desktop) {
            try {
                $shell = New-Object -ComObject WScript.Shell
                $linkPath = Join-Path $desktop 'Windows 11 Helper.lnk'
                $shortcut = $shell.CreateShortcut($linkPath)
                $shortcut.TargetPath = Join-Path $dest 'helper.bat'
                $shortcut.WorkingDirectory = $dest
                $shortcut.Description = 'Windows 11 slim helper menu'
                $shortcut.Save()
                Write-Host ("Desktop shortcut: {0}" -f $linkPath) -ForegroundColor Green
            } catch {
                Write-Warning ("Could not create the desktop shortcut: {0}" -f $_.Exception.Message)
            }
        }
    } catch {
        Write-Host ("Install failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    Pause-Menu
}

function Open-Folder {
    param([string]$Path, [string]$Label)

    if (-not (Test-Path -LiteralPath $Path)) {
        try {
            New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Host ("Could not create {0}: {1}" -f $Path, $_.Exception.Message) -ForegroundColor Red
            return
        }
    }
    try {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $Path) -ErrorAction Stop
    } catch {
        Write-Host ("Could not open {0}: {1}" -f $Label, $_.Exception.Message) -ForegroundColor Red
    }
}

function Start-Setting {
    param([string]$Target, [string]$Label)

    try {
        Start-Process -FilePath $Target -ErrorAction Stop
    } catch {
        Write-Host ("Could not open {0}: {1}" -f $Label, $_.Exception.Message) -ForegroundColor Red
        Pause-Menu
    }
}

function Show-MainMenu {
    Show-Header
    Write-Host ' Main menu' -ForegroundColor Cyan
    Write-Host ('-' * 64)
    Write-MenuItem '1' 'Create a restore point' 'enable System Restore and checkpoint now'
    Write-MenuItem '2' 'System dashboard' 'Windows, disk, restore points, tweak state, network'
    Write-MenuItem '3' 'Slim profile' 'full run and variants'
    Write-MenuItem '4' 'Performance & privacy' 'visuals, AI, telemetry, tasks, services, gaming, memory'
    Write-MenuItem '5' 'Cleanup & storage' 'quick cleanup, DISM, Disk Cleanup, Storage settings'
    Write-MenuItem '6' 'Network & access' 'RDP, autologon, IP addresses'
    Write-MenuItem '7' 'Tools & settings' 'install to C:\Tools, logs, Settings, restart Explorer/Windows'
    Write-MenuItem '8' 'Apply my Explorer preferences' 'hidden files, all extensions, open This PC'
    Write-MenuItem '9' 'Install apps' 'Everything, 7-Zip, Notepad++ from the CD'
    Write-MenuItem '10' 'Startup apps (autostart)' 'list, disable, remove or restore startup entries'
    Write-MenuItem '11' 'Stock apps & OneDrive' 'disable/uninstall OneDrive, remove stock apps, disable services'
    Write-MenuItem '12' 'SSH server (terminal access)' 'enable/disable OpenSSH, install a key, show commands'
    Write-MenuItem '13' 'Activation' 'preview only: irm https://get.activated.win | iex'
    Write-Host ''
    Write-MenuItem '0' 'Exit'
    Write-Host ''
}

function Show-ProfileMenu {
    while ($true) {
        Show-Header
        Write-Host ' Slim profile' -ForegroundColor Cyan
        Write-Host ('-' * 64)
        Write-MenuItem '1' 'Apply the full profile' 'visuals, AI, telemetry, tasks, services, gaming, cleanup'
        Write-MenuItem '2' 'Full profile, keep the Xbox app' 'adds -SkipGaming'
        Write-MenuItem '3' 'Full profile, skip cleanup' 'adds -SkipCleanup'
        Write-MenuItem '4' 'Full profile + Search/SysMain trim' 'adds -IncludeSearch -IncludeSysMain'
        Write-MenuItem '5' 'Full profile, keep stock apps' 'adds -SkipStockApps'
        Write-Host ''
        Write-MenuItem '0' 'Back'

        $choice = Read-MenuChoice 'slim'
        if ($null -eq $choice) { return }
        if ($choice -eq '') { continue }

        switch ($choice) {
            '1' {
                if (Confirm-Action 'Apply the full slim profile now? It disables services, tasks, AI features and Game DVR, removes lean stock apps, then cleans up') {
                    Invoke-Helper -Script 'minimal.ps1' -Label 'Full slim profile'
                    Write-Host 'Reboot when convenient.' -ForegroundColor Yellow
                    Pause-Menu
                }
            }
            '2' {
                if (Confirm-Action 'Apply the full profile but keep the Xbox app and services') {
                    Invoke-Helper -Script 'minimal.ps1' -Label 'Full slim profile (keep Xbox)' -Arguments @{ SkipGaming = $true }
                    Write-Host 'Reboot when convenient.' -ForegroundColor Yellow
                    Pause-Menu
                }
            }
            '3' {
                if (Confirm-Action 'Apply the full profile without cleanup') {
                    Invoke-Helper -Script 'minimal.ps1' -Label 'Full slim profile (skip cleanup)' -Arguments @{ SkipCleanup = $true }
                    Write-Host 'Reboot when convenient.' -ForegroundColor Yellow
                    Pause-Menu
                }
            }
            '4' {
                if (Confirm-Action 'Apply the full profile and disable Search indexing and SysMain') {
                    Invoke-Helper -Script 'minimal.ps1' -Label 'Full slim profile (Search/SysMain trim)' -Arguments @{ IncludeSearch = $true; IncludeSysMain = $true }
                    Write-Host 'Reboot when convenient.' -ForegroundColor Yellow
                    Pause-Menu
                }
            }
            '5' {
                if (Confirm-Action 'Apply the full profile but keep the stock apps and OneDrive') {
                    Invoke-Helper -Script 'minimal.ps1' -Label 'Full slim profile (keep stock apps)' -Arguments @{ SkipStockApps = $true }
                    Write-Host 'Reboot when convenient.' -ForegroundColor Yellow
                    Pause-Menu
                }
            }
            '0' { return }
            default {
                Write-Host 'Unknown choice.' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 700
            }
        }
    }
}

function Show-TweaksMenu {
    while ($true) {
        Show-Header
        Write-Host ' Performance & privacy' -ForegroundColor Cyan
        Write-Host ('-' * 64)
        Write-MenuItem '1' 'Visual effects: best performance' 'per user; sign out or restart Explorer'
        Write-MenuItem '2' 'AI, search and suggestions' 'Copilot, Recall, Widgets, web search, Start recommendations'
        Write-MenuItem '3' 'Telemetry and feedback' 'diagnostic data, activity history, advertising ID'
        Write-MenuItem '4' 'Scheduled background tasks' 'compatibility, CEIP, feedback, diagnostics, Maps'
        Write-MenuItem '5' 'Unused services' 'Maps, Fax, RemoteRegistry, RetailDemo, WMP sharing'
        Write-MenuItem '6' 'Gaming features' 'Game DVR, Game Bar, Xbox services (breaks the Xbox app)'
        Write-MenuItem '7' 'Memory trim' 'OneDrive startup, Widgets, background apps'
        Write-MenuItem '8' 'Memory trim, aggressive' 'also Search indexing and SysMain'
        Write-MenuItem '9' 'Tune: TRIM, power plan, hibernation' 'High Performance and Fast Startup off'
        Write-MenuItem '10' 'Debloat AppX packages (lean)' 'SetupComplete.ps1 -ProfileName lean'
        Write-Host ''
        Write-MenuItem '0' 'Back'

        $choice = Read-MenuChoice 'tweaks'
        if ($null -eq $choice) { return }
        if ($choice -eq '') { continue }

        switch ($choice) {
            '1' {
                Invoke-Helper -Script 'disable-visuals.ps1' -Label 'Visual effects: best performance'
                Write-Host 'Sign out and back in, or use Tools > Restart Explorer.' -ForegroundColor Yellow
                Pause-Menu
            }
            '2' {
                Invoke-Helper -Script 'disable-ai.ps1' -Label 'AI, search and suggestions'
                Pause-Menu
            }
            '3' {
                Invoke-Helper -Script 'disable-telemetry.ps1' -Label 'Telemetry and feedback'
                Pause-Menu
            }
            '4' {
                Invoke-Helper -Script 'disable-scheduled-tasks.ps1' -Label 'Scheduled background tasks'
                Pause-Menu
            }
            '5' {
                Invoke-Helper -Script 'optimize-services.ps1' -Label 'Unused services'
                Pause-Menu
            }
            '6' {
                if (Confirm-Action 'Disable Game DVR and the Xbox services? The Xbox app and Game Pass will stop working') {
                    Invoke-Helper -Script 'disable-gaming.ps1' -Label 'Gaming features'
                    Pause-Menu
                }
            }
            '7' {
                Invoke-Helper -Script 'trim-memory.ps1' -Label 'Memory trim'
                Pause-Menu
            }
            '8' {
                if (Confirm-Action 'Disable Search indexing and SysMain as well') {
                    Invoke-Helper -Script 'trim-memory.ps1' -Label 'Memory trim, aggressive' -Arguments @{ DisableSearch = $true; DisableSysMain = $true }
                    Pause-Menu
                }
            }
            '9' {
                Invoke-Helper -Script 'tune.ps1' -Label 'TRIM, power plan and hibernation'
                Pause-Menu
            }
            '10' {
                if (Confirm-Action 'Remove the provisioned consumer AppX packages (lean profile)') {
                    Invoke-Helper -Script 'SetupComplete.ps1' -Label 'Debloat AppX packages (lean)' -Arguments @{ ProfileName = 'lean' }
                    Pause-Menu
                }
            }
            '0' { return }
            default {
                Write-Host 'Unknown choice.' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 700
            }
        }
    }
}

function Show-CleanupMenu {
    while ($true) {
        Show-Header
        Write-Host ' Cleanup & storage' -ForegroundColor Cyan
        Write-Host ('-' * 64)
        Write-MenuItem '1' 'Quick cleanup' 'temp, Delivery Optimization, thumbnails, WER, CBS logs'
        Write-MenuItem '2' 'Dry run' 'show what quick cleanup would remove'
        Write-MenuItem '3' 'Clear the Windows Update download cache' 'stops and restarts Windows Update briefly'
        Write-MenuItem '4' 'DISM component cleanup' 'can take several minutes'
        Write-MenuItem '5' 'DISM cleanup + ResetBase' 'installed updates become non-removable'
        Write-MenuItem '6' 'Disk Cleanup' 'classic cleanmgr.exe'
        Write-MenuItem '7' 'Storage settings' 'Windows Storage Sense'
        Write-Host ''
        Write-MenuItem '0' 'Back'

        $choice = Read-MenuChoice 'cleanup'
        if ($null -eq $choice) { return }
        if ($choice -eq '') { continue }

        switch ($choice) {
            '1' {
                if (Confirm-Action 'Delete temporary files, caches, WER data and CBS logs') {
                    Invoke-Helper -Script 'cleanup.ps1' -Label 'Quick cleanup'
                    Pause-Menu
                }
            }
            '2' {
                Invoke-Helper -Script 'cleanup.ps1' -Label 'Cleanup dry run' -Arguments @{ DryRun = $true }
                Pause-Menu
            }
            '3' {
                if (Confirm-Action 'Stop Windows Update briefly and clear its download cache') {
                    Invoke-Helper -Script 'cleanup.ps1' -Label 'Windows Update cache cleanup' -Arguments @{ WindowsUpdateCache = $true }
                    Pause-Menu
                }
            }
            '4' {
                if (Confirm-Action 'Run DISM component cleanup? This can take several minutes') {
                    Invoke-Helper -Script 'cleanup.ps1' -Label 'DISM component cleanup' -Arguments @{ ComponentCleanup = $true }
                    Pause-Menu
                }
            }
            '5' {
                if (Confirm-Action 'Run component cleanup with ResetBase? Installed updates become non-removable') {
                    Invoke-Helper -Script 'cleanup.ps1' -Label 'DISM cleanup with ResetBase' -Arguments @{ ComponentCleanup = $true; ResetBase = $true }
                    Pause-Menu
                }
            }
            '6' { Start-Setting -Target 'cleanmgr.exe' -Label 'Disk Cleanup' }
            '7' { Start-Setting -Target 'ms-settings:storagesense' -Label 'Storage settings' }
            '0' { return }
            default {
                Write-Host 'Unknown choice.' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 700
            }
        }
    }
}

function Show-NetworkMenu {
    while ($true) {
        Show-Header
        Write-Host ' Network & access' -ForegroundColor Cyan
        Write-Host ('-' * 64)
        Write-MenuItem '1' 'Enable RDP' 'starts TermService and creates the TCP 3389 rule'
        Write-MenuItem '2' 'Disable RDP' 'blocks RDP and removes the rule'
        Write-MenuItem '3' 'Enable automatic logon' 'stores the password in the Winlogon key'
        Write-MenuItem '4' 'Disable automatic logon' 'removes the stored password'
        Write-MenuItem '5' 'Show IP addresses and RDP listener'
        Write-Host ''
        Write-MenuItem '0' 'Back'

        $choice = Read-MenuChoice 'network'
        if ($null -eq $choice) { return }
        if ($choice -eq '') { continue }

        switch ($choice) {
            '1' {
                Invoke-Helper -Script 'enable-rdp.ps1' -Label 'Enable RDP'
                Pause-Menu
            }
            '2' {
                if (Confirm-Action 'Disable Remote Desktop and remove the RDP 3389 firewall rule') {
                    Invoke-Helper -Script 'disable-rdp.ps1' -Label 'Disable RDP'
                    Pause-Menu
                }
            }
            '3' {
                if (Confirm-Action 'Enable automatic logon? The password is stored in the Winlogon registry key') {
                    Invoke-Helper -Script 'enable-autologon.ps1' -Label 'Enable automatic logon'
                    Pause-Menu
                }
            }
            '4' {
                Invoke-Helper -Script 'disable-autologon.ps1' -Label 'Disable automatic logon'
                Pause-Menu
            }
            '5' {
                Show-NetworkInfo
                Pause-Menu
            }
            '0' { return }
            default {
                Write-Host 'Unknown choice.' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 700
            }
        }
    }
}

function Show-SettingsMenu {
    while ($true) {
        Show-Header
        Write-Host ' Windows settings' -ForegroundColor Cyan
        Write-Host ('-' * 64)
        Write-MenuItem '1' 'Windows Update'
        Write-MenuItem '2' 'Privacy & security'
        Write-MenuItem '3' 'Installed apps'
        Write-MenuItem '4' 'Storage'
        Write-MenuItem '5' 'System about'
        Write-Host ''
        Write-MenuItem '0' 'Back'

        $choice = Read-MenuChoice 'settings'
        if ($null -eq $choice) { return }
        if ($choice -eq '') { continue }

        switch ($choice) {
            '1' { Start-Setting -Target 'ms-settings:windowsupdate' -Label 'Windows Update' }
            '2' { Start-Setting -Target 'ms-settings:privacy' -Label 'Privacy & security' }
            '3' { Start-Setting -Target 'ms-settings:appsfeatures' -Label 'Installed apps' }
            '4' { Start-Setting -Target 'ms-settings:storagesense' -Label 'Storage' }
            '5' { Start-Setting -Target 'ms-settings:about' -Label 'System about' }
            '0' { return }
            default {
                Write-Host 'Unknown choice.' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 700
            }
        }
    }
}

function Show-AdminToolsMenu {
    while ($true) {
        Show-Header
        Write-Host ' Administrative tools' -ForegroundColor Cyan
        Write-Host ('-' * 64)
        Write-MenuItem '1' 'Services'
        Write-MenuItem '2' 'Task Scheduler'
        Write-MenuItem '3' 'Device Manager'
        Write-MenuItem '4' 'Disk Management'
        Write-MenuItem '5' 'Disk Cleanup'
        Write-Host ''
        Write-MenuItem '0' 'Back'

        $choice = Read-MenuChoice 'admintools'
        if ($null -eq $choice) { return }
        if ($choice -eq '') { continue }

        switch ($choice) {
            '1' { Start-Setting -Target 'services.msc' -Label 'Services' }
            '2' { Start-Setting -Target 'taskschd.msc' -Label 'Task Scheduler' }
            '3' { Start-Setting -Target 'devmgmt.msc' -Label 'Device Manager' }
            '4' { Start-Setting -Target 'diskmgmt.msc' -Label 'Disk Management' }
            '5' { Start-Setting -Target 'cleanmgr.exe' -Label 'Disk Cleanup' }
            '0' { return }
            default {
                Write-Host 'Unknown choice.' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 700
            }
        }
    }
}

function Show-ToolsMenu {
    while ($true) {
        Show-Header
        Write-Host ' Tools & settings' -ForegroundColor Cyan
        Write-Host ('-' * 64)
        Write-MenuItem '1' 'Install helper to C:\Tools\windows-helper' 'copy the scripts and add a desktop shortcut'
        Write-MenuItem '2' 'Open System Restore' 'roll back to a checkpoint'
        Write-MenuItem '3' 'Open the helper folder'
        Write-MenuItem '4' 'Open the logs folder' '%ProgramData%\WindowsSlim'
        Write-MenuItem '5' 'Open README'
        Write-MenuItem '6' 'Windows settings...' 'Update, Privacy, Apps, Storage, About'
        Write-MenuItem '7' 'Administrative tools...' 'Services, Task Scheduler, Device Manager'
        Write-MenuItem '8' 'Restart Explorer' 'apply visual changes without signing out'
        Write-MenuItem '9' 'Restart Windows' '15 second delay, cancellable'
        Write-MenuItem '10' 'Cancel pending restart'
        Write-Host ''
        Write-MenuItem '0' 'Back'

        $choice = Read-MenuChoice 'tools'
        if ($null -eq $choice) { return }
        if ($choice -eq '') { continue }

        switch ($choice) {
            '1' { Install-Helper }
            '2' {
                Write-Host ''
                Write-Host 'Opening System Restore. Pick the "Before debloat" checkpoint.' -ForegroundColor Yellow
                Start-Setting -Target 'rstrui.exe' -Label 'System Restore'
                Pause-Menu
            }
            '3' { Open-Folder -Path $scriptRoot -Label 'the helper folder' }
            '4' { Open-Folder -Path (Join-Path $env:ProgramData 'WindowsSlim') -Label 'the logs folder' }
            '5' {
                $readme = Join-Path $scriptRoot 'README.md'
                if (Test-Path -LiteralPath $readme) {
                    try {
                        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $readme) -ErrorAction Stop
                    } catch {
                        Write-Host ("Could not open the README: {0}" -f $_.Exception.Message) -ForegroundColor Red
                        Pause-Menu
                    }
                } else {
                    Write-Host 'README.md is not on this CD.' -ForegroundColor Yellow
                    Pause-Menu
                }
            }
            '6' { Show-SettingsMenu }
            '7' { Show-AdminToolsMenu }
            '8' {
                if (Confirm-Action 'Restart Explorer? Open Explorer windows will close') {
                    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 2
                    Write-Host 'Explorer restarted.' -ForegroundColor Green
                    Pause-Menu
                }
            }
            '9' {
                if (Confirm-Action 'Restart Windows in 15 seconds? Save your work first') {
                    $null = & shutdown.exe /r /t 15 /c 'Windows helper restart'
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host 'Restart scheduled in 15 seconds. Use Tools > Cancel pending restart to abort.' -ForegroundColor Yellow
                    } else {
                        Write-Host ('Could not schedule the restart (shutdown exit {0}).' -f $LASTEXITCODE) -ForegroundColor Red
                    }
                    Pause-Menu
                }
            }
            '10' {
                $null = & shutdown.exe /a
                if ($LASTEXITCODE -ne 0) {
                    Write-Host 'No restart was pending.' -ForegroundColor Yellow
                }
                Pause-Menu
            }
            '0' { return }
            default {
                Write-Host 'Unknown choice.' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 700
            }
        }
    }
}

function Show-AutostartMenu {
    while ($true) {
        Show-Header
        Write-Host ' Startup apps (autostart)' -ForegroundColor Cyan
        Write-Host ('-' * 64)
        Write-MenuItem '1' 'List startup entries' 'Run keys, Startup folders, packaged apps'
        Write-MenuItem '2' 'Disable non-essential entries' 'Task Manager-style; a backup is written first'
        Write-MenuItem '3' 'Disable everything (aggressive)' 'also disables the security/input/audio whitelist'
        Write-MenuItem '4' 'Remove non-essential Run values' 'deletes values after a backup'
        Write-MenuItem '5' 'Restore the latest backup'
        Write-MenuItem '6' 'Open Windows Startup settings'
        Write-Host ''
        Write-MenuItem '0' 'Back'

        $choice = Read-MenuChoice 'autostart'
        if ($null -eq $choice) { return }
        if ($choice -eq '') { continue }

        switch ($choice) {
            '1' {
                Invoke-Helper -Script 'trim-autostart.ps1' -Label 'Startup entries' -Arguments @{ List = $true }
                Pause-Menu
            }
            '2' {
                if (Confirm-Action 'Disable non-essential startup entries? A backup is written first') {
                    Invoke-Helper -Script 'trim-autostart.ps1' -Label 'Disable startup entries'
                    Pause-Menu
                }
            }
            '3' {
                if (Confirm-Action 'Disable ALL startup entries, including the security/input/audio whitelist') {
                    Invoke-Helper -Script 'trim-autostart.ps1' -Label 'Disable all startup entries' -Arguments @{ Aggressive = $true }
                    Pause-Menu
                }
            }
            '4' {
                if (Confirm-Action 'Remove non-essential Run values? A backup is written first') {
                    Invoke-Helper -Script 'trim-autostart.ps1' -Label 'Remove startup entries' -Arguments @{ Remove = $true }
                    Pause-Menu
                }
            }
            '5' {
                if (Confirm-Action 'Restore the latest autostart backup') {
                    Invoke-Helper -Script 'trim-autostart.ps1' -Label 'Restore startup entries' -Arguments @{ Restore = $true }
                    Pause-Menu
                }
            }
            '6' { Start-Setting -Target 'ms-settings:startupapps' -Label 'Startup settings' }
            '0' { return }
            default {
                Write-Host 'Unknown choice.' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 700
            }
        }
    }
}

function Show-SshMenu {
    while ($true) {
        Show-Header
        Write-Host ' SSH server (terminal access)' -ForegroundColor Cyan
        Write-Host ('-' * 64)
        Write-MenuItem '1' 'Enable SSH server' 'installs OpenSSH.Server, starts sshd, opens TCP 22'
        Write-MenuItem '2' 'Disable SSH server' 'stops sshd and disables the firewall rule'
        Write-MenuItem '3' 'Show SSH status and connection command'
        Write-MenuItem '4' 'Install an SSH public key' 'enables SSH and installs the key for passwordless login'
        Write-MenuItem '5' 'Uninstall OpenSSH Server' 'removes the capability; keys and config stay'
        Write-Host ''
        Write-MenuItem '0' 'Back'

        $choice = Read-MenuChoice 'ssh'
        if ($null -eq $choice) { return }
        if ($choice -eq '') { continue }

        switch ($choice) {
            '1' {
                if (Confirm-Action 'Install and enable OpenSSH Server on port 22') {
                    Invoke-Helper -Script 'enable-ssh.ps1' -Label 'Enable SSH server'
                    Pause-Menu
                }
            }
            '2' {
                if (Confirm-Action 'Stop sshd and disable the SSH firewall rule') {
                    Invoke-Helper -Script 'enable-ssh.ps1' -Label 'Disable SSH server' -Arguments @{ Disable = $true }
                    Pause-Menu
                }
            }
            '3' {
                Invoke-Helper -Script 'enable-ssh.ps1' -Label 'SSH status' -Arguments @{ Status = $true }
                Pause-Menu
            }
            '4' {
                $keyPath = Read-Host 'Path to the public key (for example C:\Tools\id_ed25519.pub)'
                if (-not [string]::IsNullOrWhiteSpace($keyPath)) {
                    if (Confirm-Action ("Install {0} and enable SSH" -f $keyPath.Trim())) {
                        Invoke-Helper -Script 'enable-ssh.ps1' -Label 'Enable SSH with public key' `
                            -Arguments @{ PublicKeyPath = $keyPath.Trim() }
                        Pause-Menu
                    }
                }
            }
            '5' {
                if (Confirm-Action 'Remove the OpenSSH Server capability? Keys and sshd_config stay') {
                    Invoke-Helper -Script 'enable-ssh.ps1' -Label 'Uninstall OpenSSH Server' -Arguments @{ Uninstall = $true }
                    Pause-Menu
                }
            }
            '0' { return }
            default {
                Write-Host 'Unknown choice.' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 700
            }
        }
    }
}

$isAdmin = Test-Admin
Write-Log ('start user={0} admin={1} path={2}' -f $env:USERNAME, $isAdmin, $scriptRoot)

while ($running) {
    Show-MainMenu

    $choice = Read-MenuChoice 'main'
    if ($null -eq $choice) {
        break
    }
    if ($choice -eq '') {
        continue
    }

    switch ($choice) {
        '1' {
            Invoke-Helper -Script 'create-restore-point.ps1' -Label 'Create a restore point'
            Write-Host 'The checkpoint is named "Before debloat".' -ForegroundColor Yellow
            Pause-Menu
        }
        '2' {
            Show-Dashboard
            Pause-Menu
        }
        '3' { Show-ProfileMenu }
        '4' { Show-TweaksMenu }
        '5' { Show-CleanupMenu }
        '6' { Show-NetworkMenu }
        '7' { Show-ToolsMenu }
        '8' {
            if (Confirm-Action 'Apply Explorer preferences: show hidden files, show all extensions, open This PC') {
                $showProtected = Confirm-Action 'Also show protected operating system files? Not recommended'
                $restartExplorer = Confirm-Action 'Restart Explorer now to apply everything'
                $explorerArgs = @{}
                if ($showProtected) { $explorerArgs['ShowProtectedSystemFiles'] = $true }
                if ($restartExplorer) { $explorerArgs['RestartExplorer'] = $true }
                Invoke-Helper -Script 'apply-explorer-preferences.ps1' -Label 'Explorer preferences' -Arguments $explorerArgs
                Pause-Menu
            }
        }
        '9' {
            Invoke-Helper -Script 'install-apps.ps1' -Label 'Install apps'
            Pause-Menu
        }
        '10' { Show-AutostartMenu }
        '11' {
            Invoke-Helper -Script 'trim-stock.ps1' -Label 'Stock apps, OneDrive and services'
            Pause-Menu
        }
        '12' { Show-SshMenu }
        '13' {
            Write-Host ''
            Write-Host 'Activation' -ForegroundColor Magenta
            Write-Host ('-' * 64)
            Write-Host 'Command: irm https://get.activated.win | iex'
            Write-Host 'This is activates windows. A network request is made and a third-party script will be executed.' -ForegroundColor Yellow
            Pause-Menu
        }
        '0' {
            $running = $false
        }
        default {
            Write-Host 'Unknown choice.' -ForegroundColor Yellow
            Start-Sleep -Milliseconds 700
        }
    }
}

Write-Log 'exit'
Write-Host ''
Write-Host 'Done.' -ForegroundColor Green