# Interactive tabbed helper UI for the Windows helper CD.
#
# Arrow keys: left/right switch tabs, up/down select, Enter opens/applies,
# Escape goes back, Q quits. The tabs are Restore, Profiles and Changes.

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\WindowsSlim\windows-helper-menu.log",
    [string[]]$TestKeys
)

$ErrorActionPreference = 'Continue'
$scriptRoot = $PSScriptRoot
$script:LastHelperOk = $false
$script:TestQueue = New-Object System.Collections.Queue
if ($TestKeys) {
    if ($TestKeys.Count -eq 1 -and $TestKeys[0] -match ',') {
        $TestKeys = @($TestKeys[0] -split ',')
    }
    foreach ($key in $TestKeys) {
        [void]$script:TestQueue.Enqueue([string]$key)
    }
}

$logDir = Split-Path -Parent $LogPath
try {
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
} catch {
    # Logging is best-effort; the UI must still start.
}function Test-Admin {
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

function Get-TuiWidth {
    try {
        $width = [Console]::WindowWidth
    } catch {
        $width = 80
    }
    if (-not $width -or $width -lt 50) {
        $width = 80
    }
    return [int]$width
}

function Get-TuiHeight {
    try {
        $height = [Console]::WindowHeight
    } catch {
        $height = 30
    }
    if (-not $height -or $height -lt 15) {
        $height = 30
    }
    return [int]$height
}

function Format-TuiText {
    param(
        [string]$Text,
        [int]$Width
    )

    if (-not $Text) {
        return ''
    }
    $Text = $Text -replace '\r?\n', ' '
    if ($Width -le 3) {
        return ''
    }
    if ($Text.Length -gt $Width) {
        return $Text.Substring(0, $Width - 3) + '...'
    }
    return $Text
}

function Get-SshState {
    if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
        return 'n/a'
    }
    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $service) {
        return 'off'
    }
    return [string]$service.Status
}

function Update-TuiStatus {
    $points = @(Get-RestorePoints)
    $script:Status = [pscustomobject]@{
        Admin = Test-Admin
        RestorePoints = $points.Count
        Rdp = Get-RdpState
        Ssh = Get-SshState
    }
}

function New-TuiNode {
    param(
        [string]$Label,
        [string]$Description,
        [scriptblock]$Action,
        [object[]]$Children,
        [string]$Confirm
    )

    return [pscustomobject]@{
        Label = $Label
        Description = $Description
        Action = $Action
        Children = $Children
        Confirm = $Confirm
    }
}

function Show-RestorePoints {
    $points = @(Get-RestorePoints)
    if ($points.Count -eq 0) {
        Write-Host 'No restore points found.' -ForegroundColor Yellow
        Write-Host 'Create one from the Restore tab before applying a profile.'
        return
    }
    $points |
        Sort-Object SequenceNumber -Descending |
        Select-Object SequenceNumber, Description, CreationTime |
        Format-Table -AutoSize
}

function Install-HelperToC {
    $destination = 'C:\Tools\windows-helper'
    try {
        $sourceFull = [IO.Path]::GetFullPath($scriptRoot).TrimEnd([char]'\')
        $destinationFull = [IO.Path]::GetFullPath($destination).TrimEnd([char]'\')
        if ($sourceFull -ne $destinationFull) {
            New-Item -Path $destination -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Copy-Item -Path (Join-Path $scriptRoot '*') -Destination $destination -Recurse -Force -ErrorAction Stop
            Write-Host ("Copied to {0}" -f $destination) -ForegroundColor Green
        } else {
            Write-Host ("Already running from {0}" -f $destination) -ForegroundColor Yellow
        }

        $desktop = [Environment]::GetFolderPath('Desktop')
        if ($desktop) {
            try {
                $shell = New-Object -ComObject WScript.Shell
                $linkPath = Join-Path $desktop 'Windows 11 Helper.lnk'
                $shortcut = $shell.CreateShortcut($linkPath)
                $shortcut.TargetPath = Join-Path $destination 'helper.bat'
                $shortcut.WorkingDirectory = $destination
                $shortcut.Description = 'Windows 11 slim helper'
                $shortcut.Save()
                Write-Host ("Desktop shortcut: {0}" -f $linkPath) -ForegroundColor Green
            } catch {
                Write-Warning ("Could not create shortcut: {0}" -f $_.Exception.Message)
            }
        }
    } catch {
        Write-Host ("Install failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Read-TuiKey {
    if ($script:TestQueue.Count -gt 0) {
        return [string]$script:TestQueue.Dequeue()
    }

    try {
        $key = [Console]::ReadKey($true)
    } catch {
        return 'Quit'
    }

    switch ([string]$key.Key) {
        'LeftArrow' { return 'Left' }
        'RightArrow' { return 'Right' }
        'UpArrow' { return 'Up' }
        'DownArrow' { return 'Down' }
        'Enter' { return 'Enter' }
        'Escape' { return 'Escape' }
    }

    switch ([string]$key.KeyChar) {
        'q' { return 'Quit' }
        'Q' { return 'Quit' }
        'y' { return 'y' }
        'Y' { return 'y' }
        'j' { return 'y' }
        'J' { return 'y' }
        'n' { return 'n' }
        'N' { return 'n' }
    }
    return 'None'
}

function Read-TuiConfirm {
    param([string]$Question)

    Write-Host ''
    Write-Host (" {0} [y/N] " -f $Question) -ForegroundColor Yellow -NoNewline
    while ($true) {
        $key = Read-TuiKey
        if ($key -eq 'y') {
            Write-Host 'y'
            return $true
        }
        if ($key -in @('n', 'Enter', 'Escape', 'Quit')) {
            Write-Host 'n'
            return $false
        }
    }
}

function Invoke-TuiAction {
    param($Item)

    Clear-Host
    Write-Host ("==> {0}" -f $Item.Label) -ForegroundColor Cyan
    if ($Item.Description) {
        Write-Host ("    {0}" -f $Item.Description) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Log ("tui action: {0}" -f $Item.Label)

    if ($Item.Action) {
        try {
            & $Item.Action
        } catch {
            Write-Host ("Failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
            Write-Log ("tui error {0}: {1}" -f $Item.Label, $_.Exception.Message)
        }
    }

    Update-TuiStatus
    Write-Host ''
    if ($script:TestQueue.Count -eq 0) {
        Write-Host 'Press any key to return.' -ForegroundColor DarkGray
        try {
            [void][Console]::ReadKey($true)
        } catch {
            # Non-interactive host; just return.
        }
    }
}

function Render-Tui {
    $width = Get-TuiWidth
    $height = Get-TuiHeight
    Clear-Host

    Write-Host ('=' * $width) -ForegroundColor DarkCyan
    Write-Host ' Windows 11 helper' -ForegroundColor Cyan
    $statusLine = " {0} | admin: {1} | restore: {2} | RDP: {3} | SSH: {4}" -f `
        $env:COMPUTERNAME,
        $(if ($script:Status.Admin) { 'yes' } else { 'no' }),
        $script:Status.RestorePoints,
        $script:Status.Rdp,
        $script:Status.Ssh
    Write-Host (Format-TuiText $statusLine ($width - 1)) -ForegroundColor Gray
    if (-not $script:Status.Admin) {
        Write-Host ' WARNING: not elevated. Close this and run helper.bat.' -ForegroundColor Red
    }
    Write-Host ''

    for ($i = 0; $i -lt $script:Tabs.Count; $i++) {
        $label = ' [ {0} ] ' -f $script:Tabs[$i].Title
        if ($i -eq $script:TabIndex) {
            Write-Host $label -NoNewline -ForegroundColor Black -BackgroundColor Cyan
        } else {
            Write-Host $label -NoNewline -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Host ('-' * $width) -ForegroundColor DarkGray

    if ($script:Breadcrumbs.Count -gt 1) {
        $crumb = $script:Breadcrumbs -join ' > '
        Write-Host (' ' + (Format-TuiText $crumb ($width - 2))) -ForegroundColor DarkCyan
    }

    $items = @($script:CurrentItems)
    $count = $items.Count
    if ($count -eq 0) {
        Write-Host ' No entries.' -ForegroundColor Yellow
    } else {
        $pageSize = [Math]::Max(4, $height - 12)
        $start = $script:Selected - [int][Math]::Floor($pageSize / 2)
        if ($start -lt 0) { $start = 0 }
        if (($start + $pageSize) -gt $count) {
            $start = [Math]::Max(0, $count - $pageSize)
        }
        $end = [Math]::Min($count, $start + $pageSize)

        for ($i = $start; $i -lt $end; $i++) {
            $node = $items[$i]
            $suffix = if ($node.Children) { ' ...' } else { '' }
            $marker = if ($i -eq $script:Selected) { '>' } else { ' ' }
            $line = ' {0} {1}{2}' -f $marker, $node.Label, $suffix
            if ($i -eq $script:Selected) {
                Write-Host (Format-TuiText $line ($width - 1)) -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host (Format-TuiText $line ($width - 1))
            }
        }
    }

    $selectedNode = if ($count -gt 0) { $items[$script:Selected] } else { $null }
    if ($selectedNode -and $selectedNode.Description) {
        Write-Host ''
        Write-Host (' ' + (Format-TuiText $selectedNode.Description ($width - 2))) -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host ' ←/→ tabs   ↑/↓ select   Enter open/apply   Esc back   Q quit' -ForegroundColor DarkGray
}

function Set-TuiTab {
    param([int]$Index)

    $script:TabIndex = $Index
    $script:Stack = New-Object System.Collections.Stack
    $script:CurrentItems = @($script:Tabs[$Index].Items)
    $script:Selected = 0
    $script:Breadcrumbs = @($script:Tabs[$Index].Title)
}

function Push-TuiNode {
    param($Node)

    $script:Stack.Push([pscustomobject]@{
        Items = $script:CurrentItems
        Selected = $script:Selected
        Breadcrumbs = $script:Breadcrumbs
    })
    $script:CurrentItems = @($Node.Children)
    $script:Selected = 0
    $script:Breadcrumbs = @($script:Breadcrumbs + $Node.Label)
}

function Pop-Tui {
    if ($script:Stack.Count -eq 0) {
        return
    }
    $state = $script:Stack.Pop()
    $script:CurrentItems = @($state.Items)
    $script:Selected = $state.Selected
    $script:Breadcrumbs = @($state.Breadcrumbs)
}

function Move-TuiSelection {
    param([int]$Delta)

    $count = @($script:CurrentItems).Count
    if ($count -eq 0) {
        return
    }
    $script:Selected = ($script:Selected + $Delta + $count) % $count
}

$startupItems = @(
    New-TuiNode -Label 'List startup entries' -Description 'Run keys, Startup folders and packaged-app tasks.' -Action {
        Invoke-Helper -Script 'trim-autostart.ps1' -Label 'Startup entries' -Arguments @{ List = $true }
    }
    New-TuiNode -Label 'Disable non-essential entries' -Description 'Task Manager-style disable; a backup is written first.' -Confirm 'Disable non-essential startup entries?' -Action {
        Invoke-Helper -Script 'trim-autostart.ps1' -Label 'Disable startup entries'
    }
    New-TuiNode -Label 'Disable everything (aggressive)' -Description 'Disables all startup entries except ctfmon.' -Confirm 'Disable all startup entries?' -Action {
        Invoke-Helper -Script 'trim-autostart.ps1' -Label 'Disable all startup entries' -Arguments @{ Aggressive = $true }
    }
    New-TuiNode -Label 'Remove non-essential Run values' -Description 'Deletes Run values after a backup.' -Confirm 'Remove non-essential Run values?' -Action {
        Invoke-Helper -Script 'trim-autostart.ps1' -Label 'Remove startup entries' -Arguments @{ Remove = $true }
    }
    New-TuiNode -Label 'Restore latest backup' -Description 'Restores Run values, Startup folders and packaged-task states.' -Confirm 'Restore the latest startup backup?' -Action {
        Invoke-Helper -Script 'trim-autostart.ps1' -Label 'Restore startup entries' -Arguments @{ Restore = $true }
    }
    New-TuiNode -Label 'Open Windows Startup settings' -Description 'Review the packaged apps that remain.' -Action {
        Start-Setting -Target 'ms-settings:startupapps' -Label 'Startup settings'
    }
)

$systemItems = @(
    New-TuiNode -Label 'Visual effects: best performance' -Description 'Animations, transparency, shadows and Aero Peek off.' -Action {
        Invoke-Helper -Script 'disable-visuals.ps1' -Label 'Visual effects: best performance'
    }
    New-TuiNode -Label 'Explorer preferences' -Description 'Hidden files, all extensions, open This PC.' -Action {
        Invoke-Helper -Script 'apply-explorer-preferences.ps1' -Label 'Explorer preferences'
    }
    New-TuiNode -Label 'Explorer preferences + restart' -Description 'Apply the preferences and restart Explorer.' -Confirm 'Restart Explorer as well?' -Action {
        Invoke-Helper -Script 'apply-explorer-preferences.ps1' -Label 'Explorer preferences + restart' -Arguments @{ RestartExplorer = $true }
    }
    New-TuiNode -Label 'Explorer preferences + protected files' -Description 'Also show protected operating system files.' -Confirm 'Show protected operating system files too?' -Action {
        Invoke-Helper -Script 'apply-explorer-preferences.ps1' -Label 'Explorer preferences + protected files' -Arguments @{ ShowProtectedSystemFiles = $true }
    }
    New-TuiNode -Label 'Tune: TRIM, power and hibernation' -Description 'High Performance plan, TRIM on, Fast Startup off.' -Action {
        Invoke-Helper -Script 'tune.ps1' -Label 'TRIM, power and hibernation'
    }
    New-TuiNode -Label 'Startup apps...' -Description 'Nested startup cleanup and restore.' -Children $startupItems
    New-TuiNode -Label 'System dashboard' -Description 'Windows, disk, restore points, tweak state and network.' -Action {
        Show-Dashboard
    }
)

$privacyItems = @(
    New-TuiNode -Label 'AI, search and suggestions' -Description 'Copilot, Recall, Click to Do, Widgets, web search and recommendations.' -Action {
        Invoke-Helper -Script 'disable-ai.ps1' -Label 'AI, search and suggestions'
    }
    New-TuiNode -Label 'Telemetry and feedback' -Description 'Diagnostic data, activity history and advertising ID.' -Action {
        Invoke-Helper -Script 'disable-telemetry.ps1' -Label 'Telemetry and feedback'
    }
    New-TuiNode -Label 'Scheduled background tasks' -Description 'Compatibility, CEIP, feedback, diagnostics and Maps tasks.' -Action {
        Invoke-Helper -Script 'disable-scheduled-tasks.ps1' -Label 'Scheduled background tasks'
    }
    New-TuiNode -Label 'Open Privacy settings' -Description 'Windows Settings, Privacy and security.' -Action {
        Start-Setting -Target 'ms-settings:privacy' -Label 'Privacy settings'
    }
)

$stockItems = @(
    New-TuiNode -Label 'Conservative services' -Description 'telemetry, Maps, Fax, RemoteRegistry, print spooler and similar.' -Action {
        Invoke-Helper -Script 'optimize-services.ps1' -Label 'Conservative services'
    }
    New-TuiNode -Label 'Balanced stock services' -Description 'Telemetry and stock extras off; printing, Bluetooth, Search and Xbox kept.' -Action {
        Invoke-Helper -Script 'trim-stock.ps1' -Label 'Balanced stock services' -Arguments @{ Services = 'Balanced' }
    }
    New-TuiNode -Label 'Lean stock services' -Description 'Balanced plus Xbox and printing services off.' -Confirm 'Disable lean stock services?' -Action {
        Invoke-Helper -Script 'trim-stock.ps1' -Label 'Lean stock services' -Arguments @{ Services = 'Lean' }
    }
    New-TuiNode -Label 'Aggressive stock services' -Description 'Also Bluetooth, Wi-Fi, camera, notifications, diagnostics and Search.' -Confirm 'Disable the aggressive service set?' -Action {
        Invoke-Helper -Script 'trim-stock.ps1' -Label 'Aggressive stock services' -Arguments @{ Services = 'Aggressive' }
    }
    New-TuiNode -Label 'OneDrive: disable sync and startup' -Description 'Keeps local files; removes the startup entry and sync policy.' -Confirm 'Disable OneDrive sync and startup?' -Action {
        Invoke-Helper -Script 'trim-stock.ps1' -Label 'Disable OneDrive' -Arguments @{ OneDrive = 'Disable' }
    }
    New-TuiNode -Label 'OneDrive: uninstall' -Description 'Runs OneDriveSetup.exe /uninstall; local files stay.' -Confirm 'Uninstall OneDrive? Local files are kept.' -Action {
        Invoke-Helper -Script 'trim-stock.ps1' -Label 'Uninstall OneDrive' -Arguments @{ OneDrive = 'Remove' }
    }
    New-TuiNode -Label 'Remove lean stock apps' -Description 'Bing apps, Xbox, Office Hub, Teams, Clipchamp, Solitaire and similar.' -Confirm 'Remove the lean list of stock apps?' -Action {
        Invoke-Helper -Script 'trim-stock.ps1' -Label 'Remove lean stock apps' -Arguments @{ Apps = 'Lean' }
    }
    New-TuiNode -Label 'Remove aggressive stock apps' -Description 'Lean list plus Store and Store Purchase App.' -Confirm 'Remove the aggressive stock app list, including Store?' -Action {
        Invoke-Helper -Script 'trim-stock.ps1' -Label 'Remove aggressive stock apps' -Arguments @{ Apps = 'Aggressive' }
    }
    New-TuiNode -Label 'Restore service startup types' -Description 'Restores the saved service configuration.' -Confirm 'Restore saved service startup types?' -Action {
        Invoke-Helper -Script 'trim-stock.ps1' -Label 'Restore service startup types' -Arguments @{ RestoreServices = $true }
    }
    New-TuiNode -Label 'Restore OneDrive policy' -Description 'Re-enables the policy and starts OneDrive if installed.' -Confirm 'Restore the OneDrive policy?' -Action {
        Invoke-Helper -Script 'trim-stock.ps1' -Label 'Restore OneDrive' -Arguments @{ RestoreOneDrive = $true }
    }
    New-TuiNode -Label 'Stock status' -Description 'OneDrive, app and service status.' -Action {
        Invoke-Helper -Script 'trim-stock.ps1' -Label 'Stock status' -Arguments @{ List = $true }
    }
    New-TuiNode -Label 'Gaming features' -Description 'Game DVR, Game Bar and Xbox services; breaks the Xbox app.' -Confirm 'Disable Game DVR and Xbox services?' -Action {
        Invoke-Helper -Script 'disable-gaming.ps1' -Label 'Gaming features'
    }
    New-TuiNode -Label 'Memory trim' -Description 'OneDrive startup, Widgets, Recall and background apps.' -Action {
        Invoke-Helper -Script 'trim-memory.ps1' -Label 'Memory trim'
    }
    New-TuiNode -Label 'Memory trim, aggressive' -Description 'Also disables Search indexing and SysMain.' -Confirm 'Disable Search indexing and SysMain too?' -Action {
        Invoke-Helper -Script 'trim-memory.ps1' -Label 'Memory trim, aggressive' -Arguments @{ DisableSearch = $true; DisableSysMain = $true }
    }
)

$networkItems = @(
    New-TuiNode -Label 'Enable RDP' -Description 'Starts TermService, opens TCP 3389 and sets the profile to Private.' -Confirm 'Enable Remote Desktop?' -Action {
        Invoke-Helper -Script 'enable-rdp.ps1' -Label 'Enable RDP'
    }
    New-TuiNode -Label 'Disable RDP' -Description 'Blocks RDP and removes the explicit firewall rule.' -Confirm 'Disable Remote Desktop?' -Action {
        Invoke-Helper -Script 'disable-rdp.ps1' -Label 'Disable RDP'
    }
    New-TuiNode -Label 'Enable SSH server' -Description 'Installs OpenSSH Server, starts sshd and opens TCP 22.' -Confirm 'Install and enable OpenSSH Server?' -Action {
        Invoke-Helper -Script 'enable-ssh.ps1' -Label 'Enable SSH server'
    }
    New-TuiNode -Label 'Disable SSH server' -Description 'Stops sshd and disables the SSH firewall rule.' -Confirm 'Disable SSH?' -Action {
        Invoke-Helper -Script 'enable-ssh.ps1' -Label 'Disable SSH server' -Arguments @{ Disable = $true }
    }
    New-TuiNode -Label 'SSH status and connection command' -Description 'Capability, listener, firewall and ProxyJump command.' -Action {
        Invoke-Helper -Script 'enable-ssh.ps1' -Label 'SSH status' -Arguments @{ Status = $true }
    }
    New-TuiNode -Label 'SSH: install public key...' -Description 'Prompts for a .pub file and enables SSH.' -Confirm 'Install a public key and enable SSH?' -Action {
        $keyPath = Read-Host 'Path to the public key'
        if (-not [string]::IsNullOrWhiteSpace($keyPath)) {
            Invoke-Helper -Script 'enable-ssh.ps1' -Label 'Enable SSH with public key' -Arguments @{ PublicKeyPath = $keyPath.Trim() }
        } else {
            Write-Host 'Cancelled.' -ForegroundColor Yellow
        }
    }
    New-TuiNode -Label 'Uninstall OpenSSH Server' -Description 'Removes the capability; keys and config stay.' -Confirm 'Remove the OpenSSH Server capability?' -Action {
        Invoke-Helper -Script 'enable-ssh.ps1' -Label 'Uninstall OpenSSH Server' -Arguments @{ Uninstall = $true }
    }
    New-TuiNode -Label 'Enable automatic logon' -Description 'Stores the account password in the Winlogon key.' -Confirm 'Enable automatic logon?' -Action {
        Invoke-Helper -Script 'enable-autologon.ps1' -Label 'Enable automatic logon'
    }
    New-TuiNode -Label 'Disable automatic logon' -Description 'Removes the stored password.' -Confirm 'Disable automatic logon?' -Action {
        Invoke-Helper -Script 'disable-autologon.ps1' -Label 'Disable automatic logon'
    }
    New-TuiNode -Label 'Show network and RDP info' -Description 'IPv4 addresses, RDP setting, firewall rule and listener.' -Action {
        Show-NetworkInfo
    }
)

$cleanupItems = @(
    New-TuiNode -Label 'Quick cleanup' -Description 'Temp, Delivery Optimization, thumbnails, WER and CBS logs.' -Confirm 'Delete temporary files and caches?' -Action {
        Invoke-Helper -Script 'cleanup.ps1' -Label 'Quick cleanup'
    }
    New-TuiNode -Label 'Dry run' -Description 'Shows what quick cleanup would remove.' -Action {
        Invoke-Helper -Script 'cleanup.ps1' -Label 'Cleanup dry run' -Arguments @{ DryRun = $true }
    }
    New-TuiNode -Label 'Clear Windows Update cache' -Description 'Stops Windows Update briefly and clears the download cache.' -Confirm 'Clear the Windows Update download cache?' -Action {
        Invoke-Helper -Script 'cleanup.ps1' -Label 'Windows Update cache cleanup' -Arguments @{ WindowsUpdateCache = $true }
    }
    New-TuiNode -Label 'DISM component cleanup' -Description 'Can take several minutes.' -Confirm 'Run DISM component cleanup?' -Action {
        Invoke-Helper -Script 'cleanup.ps1' -Label 'DISM component cleanup' -Arguments @{ ComponentCleanup = $true }
    }
    New-TuiNode -Label 'DISM cleanup + ResetBase' -Description 'Installed updates become non-removable.' -Confirm 'Run component cleanup with ResetBase?' -Action {
        Invoke-Helper -Script 'cleanup.ps1' -Label 'DISM cleanup with ResetBase' -Arguments @{ ComponentCleanup = $true; ResetBase = $true }
    }
    New-TuiNode -Label 'Disk Cleanup' -Description 'Classic cleanmgr.exe.' -Action {
        Start-Setting -Target 'cleanmgr.exe' -Label 'Disk Cleanup'
    }
    New-TuiNode -Label 'Storage settings' -Description 'Windows Storage Sense.' -Action {
        Start-Setting -Target 'ms-settings:storagesense' -Label 'Storage settings'
    }
)

$appsItems = @(
    New-TuiNode -Label 'Install apps...' -Description 'Interactive menu for the offline app cache.' -Action {
        Invoke-Helper -Script 'install-apps.ps1' -Label 'Install apps'
    }
    New-TuiNode -Label 'List app cache' -Description 'Shows installed state and local installer availability.' -Action {
        Invoke-Helper -Script 'install-apps.ps1' -Label 'List app cache' -Arguments @{ List = $true }
    }
    New-TuiNode -Label 'Verify installers' -Description 'Checks the SHA-256 of every cached installer.' -Action {
        Invoke-Helper -Script 'install-apps.ps1' -Label 'Verify app installers' -Arguments @{ Verify = $true }
    }
    New-TuiNode -Label 'Cleanup...' -Description 'Quick cleanup, DISM, Disk Cleanup and Storage settings.' -Children $cleanupItems
)

$settingsItems = @(
    New-TuiNode -Label 'Windows Update' -Description 'Open the Windows Update page.' -Action { Start-Setting -Target 'ms-settings:windowsupdate' -Label 'Windows Update' }
    New-TuiNode -Label 'Privacy & security' -Description 'Open the privacy page.' -Action { Start-Setting -Target 'ms-settings:privacy' -Label 'Privacy & security' }
    New-TuiNode -Label 'Installed apps' -Description 'Open the app list.' -Action { Start-Setting -Target 'ms-settings:appsfeatures' -Label 'Installed apps' }
    New-TuiNode -Label 'Storage' -Description 'Open Storage Sense.' -Action { Start-Setting -Target 'ms-settings:storagesense' -Label 'Storage' }
    New-TuiNode -Label 'System about' -Description 'Open the Windows version page.' -Action { Start-Setting -Target 'ms-settings:about' -Label 'System about' }
)

$adminItems = @(
    New-TuiNode -Label 'Services' -Description 'Open services.msc.' -Action { Start-Setting -Target 'services.msc' -Label 'Services' }
    New-TuiNode -Label 'Task Scheduler' -Description 'Open taskschd.msc.' -Action { Start-Setting -Target 'taskschd.msc' -Label 'Task Scheduler' }
    New-TuiNode -Label 'Device Manager' -Description 'Open devmgmt.msc.' -Action { Start-Setting -Target 'devmgmt.msc' -Label 'Device Manager' }
    New-TuiNode -Label 'Disk Management' -Description 'Open diskmgmt.msc.' -Action { Start-Setting -Target 'diskmgmt.msc' -Label 'Disk Management' }
    New-TuiNode -Label 'Disk Cleanup' -Description 'Open cleanmgr.exe.' -Action { Start-Setting -Target 'cleanmgr.exe' -Label 'Disk Cleanup' }
)

$toolsItems = @(
    New-TuiNode -Label 'System dashboard' -Description 'Windows, disk, restore points, tweak state and network.' -Action {
        Show-Dashboard
    }
    New-TuiNode -Label 'Install helper to C:\Tools' -Description 'Copies every script and app, and creates a desktop shortcut.' -Confirm 'Copy the helper to C:\Tools\windows-helper?' -Action {
        Install-HelperToC
    }
    New-TuiNode -Label 'Open helper folder' -Description 'Show the helpers in Explorer.' -Action {
        Open-Folder -Path $scriptRoot -Label 'the helper folder'
    }
    New-TuiNode -Label 'Open logs folder' -Description 'Open %ProgramData%\WindowsSlim.' -Action {
        Open-Folder -Path (Join-Path $env:ProgramData 'WindowsSlim') -Label 'the logs folder'
    }
    New-TuiNode -Label 'Open README' -Description 'Open the helper documentation.' -Action {
        $readme = Join-Path $scriptRoot 'README.md'
        if (Test-Path -LiteralPath $readme) {
            Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $readme) -ErrorAction SilentlyContinue
        } else {
            Write-Host 'README.md is not on this CD.' -ForegroundColor Yellow
        }
    }
    New-TuiNode -Label 'Windows settings...' -Description 'Update, Privacy, Apps, Storage and About.' -Children $settingsItems
    New-TuiNode -Label 'Administrative tools...' -Description 'Services, Task Scheduler, Device Manager and Disk Management.' -Children $adminItems
    New-TuiNode -Label 'Restart Explorer' -Description 'Applies visual changes without signing out.' -Confirm 'Restart Explorer? Open windows will close.' -Action {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Host 'Explorer restarted.' -ForegroundColor Green
    }
    New-TuiNode -Label 'Restart Windows' -Description '15 second delay; save your work first.' -Confirm 'Restart Windows in 15 seconds?' -Action {
        $null = & shutdown.exe /r /t 15 /c 'Windows helper restart'
        if ($LASTEXITCODE -eq 0) {
            Write-Host 'Restart scheduled in 15 seconds. Use Tools > Cancel pending restart to abort.' -ForegroundColor Yellow
        } else {
            Write-Host ('Could not schedule the restart (exit {0}).' -f $LASTEXITCODE) -ForegroundColor Red
        }
    }
    New-TuiNode -Label 'Cancel pending restart' -Description 'Aborts a scheduled restart.' -Action {
        $null = & shutdown.exe /a
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'No restart was pending.' -ForegroundColor Yellow
        }
    }
)

$changeItems = @(
    New-TuiNode -Label 'System & desktop' -Description 'Visuals, Explorer, power and startup.' -Children $systemItems
    New-TuiNode -Label 'Privacy & AI' -Description 'AI surfaces, telemetry and background tasks.' -Children $privacyItems
    New-TuiNode -Label 'Services & stock apps' -Description 'OneDrive, stock apps, services and gaming.' -Children $stockItems
    New-TuiNode -Label 'Network & access' -Description 'RDP, SSH, autologon and network info.' -Children $networkItems
    New-TuiNode -Label 'Apps & cleanup' -Description 'Offline app installers and cleanup tools.' -Children $appsItems
    New-TuiNode -Label 'Tools & maintenance' -Description 'Dashboard, install to C:\Tools, settings and restarts.' -Children $toolsItems
)

$restoreItems = @(
    New-TuiNode -Label 'Create a restore point' -Description 'Enable System Restore and create the Before debloat checkpoint.' -Confirm 'Create a restore point now?' -Action {
        Invoke-Helper -Script 'create-restore-point.ps1' -Label 'Create a restore point'
    }
    New-TuiNode -Label 'List restore points' -Description 'Show the available checkpoints.' -Action {
        Show-RestorePoints
    }
    New-TuiNode -Label 'Open System Restore' -Description 'Roll back to a checkpoint.' -Confirm 'Open the System Restore wizard?' -Action {
        try {
            Start-Process -FilePath 'rstrui.exe' -ErrorAction Stop
        } catch {
            Write-Host ("Could not start System Restore: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
    }
    New-TuiNode -Label 'System dashboard' -Description 'Overview of Windows, disk, restore points and tweaks.' -Action {
        Show-Dashboard
    }
)

$profileItems = @(
    New-TuiNode -Label 'Create a restore point first' -Description 'Recommended before applying any profile.' -Confirm 'Create a restore point now?' -Action {
        Invoke-Helper -Script 'create-restore-point.ps1' -Label 'Create a restore point'
    }
    New-TuiNode -Label 'Developer (most aggressive)' -Description 'Lean apps, aggressive services, SSH on, Game DVR off, cleanup.' -Confirm 'Apply the Developer profile? Stock apps are removed and aggressive services are disabled.' -Action {
        Invoke-Helper -Script 'minimal.ps1' -Label 'Developer profile' -Arguments @{ Mode = 'developer' }
    }
    New-TuiNode -Label 'Power user (balanced)' -Description 'Lean apps, balanced services, printing/Bluetooth/Search kept, cleanup.' -Confirm 'Apply the Power user profile?' -Action {
        Invoke-Helper -Script 'minimal.ps1' -Label 'Power user profile' -Arguments @{ Mode = 'power' }
    }
    New-TuiNode -Label 'Regular user (light)' -Description 'Visuals, AI/telemetry, Explorer, startup trim and OneDrive off; keeps apps and services.' -Confirm 'Apply the Regular user profile?' -Action {
        Invoke-Helper -Script 'minimal.ps1' -Label 'Regular user profile' -Arguments @{ Mode = 'regular' }
    }
)

$script:Tabs = @(
    [pscustomobject]@{ Title = 'Restore'; Items = $restoreItems }
    [pscustomobject]@{ Title = 'Profiles'; Items = $profileItems }
    [pscustomobject]@{ Title = 'Changes'; Items = $changeItems }
)

$isAdmin = Test-Admin
$script:Running = $true
$script:TabIndex = 0
$script:Stack = New-Object System.Collections.Stack
$script:Status = [pscustomobject]@{
    Admin = $isAdmin
    RestorePoints = 0
    Rdp = 'n/a'
    Ssh = 'n/a'
}
Update-TuiStatus
Set-TuiTab 0

try {
    if (-not $TestKeys) {
        try { [Console]::CursorVisible = $false } catch { }
    }

    while ($script:Running) {
        Render-Tui
        $key = Read-TuiKey

        switch ($key) {
            'Left' {
                Set-TuiTab (($script:TabIndex + $script:Tabs.Count - 1) % $script:Tabs.Count)
            }
            'Right' {
                Set-TuiTab (($script:TabIndex + 1) % $script:Tabs.Count)
            }
            'Up' {
                Move-TuiSelection -1
            }
            'Down' {
                Move-TuiSelection 1
            }
            'Enter' {
                if (@($script:CurrentItems).Count -eq 0) {
                    continue
                }
                $selectedNode = $script:CurrentItems[$script:Selected]
                if ($selectedNode.Children) {
                    Push-TuiNode $selectedNode
                } elseif ($selectedNode.Confirm) {
                    if (Read-TuiConfirm $selectedNode.Confirm) {
                        Invoke-TuiAction $selectedNode
                    }
                } else {
                    Invoke-TuiAction $selectedNode
                }
            }
            'Escape' {
                Pop-Tui
            }
            'Quit' {
                $script:Running = $false
            }
        }
    }
} finally {
    try { [Console]::CursorVisible = $true } catch { }
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green