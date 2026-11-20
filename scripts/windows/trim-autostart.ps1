# Disable non-essential Windows startup entries.
#
# Covers:
#   - HKCU/HKLM Run keys (including WOW6432Node)
#   - User and common Startup folders
#   - Packaged-app startup tasks
#
# Run entries are disabled through Explorer\StartupApproved, exactly like
# Task Manager does, so nothing is deleted. Startup folders and UWP task states
# are backed up before they are changed. Use -Restore to undo the latest run.

[CmdletBinding()]
param(
    [switch]$List,
    [switch]$Remove,
    [switch]$Restore,
    [switch]$Aggressive,
    [switch]$DryRun,
    [string[]]$Keep = @(
        'SecurityHealth',
        'RtkAudUService*',
        'SynTPEnh*',
        'ETDCtrl*',
        'vmtoolsd*',
        'VBoxTray*',
        'spice*',
        'vdservice*'
    )
)

$ErrorActionPreference = 'Continue'
$programData = if ($env:ProgramData) { $env:ProgramData } else { [IO.Path]::GetTempPath() }
$backupRoot = Join-Path $programData 'WindowsSlim\autostart-backup'
$hardKeep = @('ctfmon')
$script:KeepPatterns = if ($Aggressive) { @() } else { @($Keep) }

$runSources = @(
    [pscustomobject]@{
        Label = 'HKCU Run'
        Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        RegPath = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'
        Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        ApprovedReg = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        Backup = 'hkcu-run.reg'
        ApprovedBackup = 'hkcu-startupapproved-run.reg'
        ExtraApproved = $null
        ExtraBackup = $null
    },
    [pscustomobject]@{
        Label = 'HKLM Run'
        Key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        RegPath = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        ApprovedReg = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        Backup = 'hklm-run.reg'
        ApprovedBackup = 'hklm-startupapproved-run.reg'
        ExtraApproved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        ExtraBackup = $null
    },
    [pscustomobject]@{
        Label = 'HKLM Run32'
        Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        RegPath = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
        ApprovedReg = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
        Backup = 'hklm-run32.reg'
        ApprovedBackup = 'hklm-startupapproved-run32.reg'
        ExtraApproved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
        ExtraBackup = $null
    }
)

function Test-Keep {
    param([string]$Name)

    foreach ($pattern in $hardKeep) {
        if ($Name -like $pattern) { return $true }
    }
    foreach ($pattern in $script:KeepPatterns) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function Get-RunEntries {
    $entries = @()
    foreach ($source in $runSources) {
        if (-not (Test-Path -LiteralPath $source.Key)) {
            continue
        }
        $item = Get-Item -LiteralPath $source.Key
        foreach ($name in $item.GetValueNames()) {
            $entries += [pscustomobject]@{
                Source = $source
                Name = $name
                Command = $item.GetValue($name)
                Keep = (Test-Keep -Name $name)
            }
        }
    }
    return $entries
}

function Get-StartupFolders {
    return @(
        [pscustomobject]@{
            Label = 'User Startup'
            Path = [Environment]::GetFolderPath('Startup')
            Backup = 'Startup-User'
        },
        [pscustomobject]@{
            Label = 'Common Startup'
            Path = [Environment]::GetFolderPath('CommonStartup')
            Backup = 'Startup-Common'
        }
    )
}

function Get-StartupItems {
    $items = @()
    foreach ($folder in Get-StartupFolders) {
        if (-not $folder.Path -or -not (Test-Path -LiteralPath $folder.Path)) {
            continue
        }
        foreach ($item in Get-ChildItem -LiteralPath $folder.Path -Force -ErrorAction SilentlyContinue) {
            if ($item.Name -eq 'desktop.ini') {
                continue
            }
            $items += [pscustomobject]@{
                Folder = $folder
                Name = $item.Name
                FullName = $item.FullName
                Keep = (Test-Keep -Name $item.Name)
            }
        }
    }
    return $items
}

function Get-UwpStartupTasks {
    $root = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
    if (-not (Test-Path -LiteralPath $root)) {
        return @()
    }

    $tasks = @()
    foreach ($key in Get-ChildItem -LiteralPath $root -Recurse -Depth 2 -ErrorAction SilentlyContinue) {
        $values = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $values -or $null -eq $values.State) {
            continue
        }
        $tasks += [pscustomobject]@{
            Key = $key.PSPath
            Name = $key.Name
            Task = $key.PSChildName
            State = [int]$values.State
            Keep = (Test-Keep -Name $key.PSChildName)
        }
    }
    return $tasks
}

function Show-List {
    param(
        [object[]]$RunEntries,
        [object[]]$StartupItems,
        [object[]]$UwpTasks
    )

    Write-Host 'Run keys' -ForegroundColor Cyan
    if ($RunEntries.Count -eq 0) {
        Write-Host '  none'
    } else {
        $RunEntries |
            Select-Object @{n='Scope';e={$_.Source.Label}}, Name,
                @{n='Action';e={if ($_.Keep) { 'keep' } else { 'disable' } }}, Command |
            Format-Table -AutoSize
    }

    Write-Host 'Startup folders' -ForegroundColor Cyan
    if ($StartupItems.Count -eq 0) {
        Write-Host '  none'
    } else {
        $StartupItems |
            Select-Object @{n='Scope';e={$_.Folder.Label}}, Name,
                @{n='Action';e={if ($_.Keep) { 'keep' } else { 'move to backup' } }} |
            Format-Table -AutoSize
    }

    Write-Host 'Packaged app startup tasks' -ForegroundColor Cyan
    if ($UwpTasks.Count -eq 0) {
        Write-Host '  none'
    } else {
        $UwpTasks |
            Select-Object Task,
                @{n='State';e={switch ($_.State) { 0 { 'disabled' } 1 { 'disabled by user' } 2 { 'enabled' } 3 { 'disabled by policy' } 4 { 'enabled by policy' } default { $_.State } } }},
                @{n='Action';e={if ($_.Keep -or $_.State -in 0,1,3) { 'keep' } else { 'disable' } }} |
            Format-Table -AutoSize
    }
}

function Export-RegKey {
    param(
        [string]$PsPath,
        [string]$RegPath,
        [string]$File
    )

    if (-not (Test-Path -LiteralPath $PsPath)) {
        return
    }
    & reg.exe export $RegPath $File /y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning ("Could not export {0}" -f $RegPath)
    }
}

function Backup-State {
    param(
        [object[]]$RunEntries,
        [object[]]$StartupItems,
        [object[]]$UwpTasks
    )

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $backupRoot $timestamp
    New-Item -Path $backup -ItemType Directory -Force | Out-Null

    foreach ($source in $runSources) {
        Export-RegKey -PsPath $source.Key -RegPath $source.RegPath -File (Join-Path $backup $source.Backup)
        Export-RegKey -PsPath $source.Approved -RegPath $source.ApprovedReg -File (Join-Path $backup $source.ApprovedBackup)
    }

    $approvedStates = @()
    foreach ($entry in $RunEntries) {
        $targets = @($entry.Source.Approved)
        if ($entry.Source.ExtraApproved) {
            $targets += $entry.Source.ExtraApproved
        }
        foreach ($target in $targets) {
            $encoded = $null
            $property = Get-ItemProperty -Path $target -Name $entry.Name -ErrorAction SilentlyContinue
            if ($null -ne $property) {
                $valueProperty = $property.PSObject.Properties[$entry.Name]
                if ($null -ne $valueProperty -and $null -ne $valueProperty.Value) {
                    try {
                        $encoded = [Convert]::ToBase64String([byte[]]$valueProperty.Value)
                    } catch {
                        $encoded = $null
                    }
                }
            }
            $approvedStates += [pscustomobject]@{
                Path = $target
                Name = $entry.Name
                Value = $encoded
            }
        }
    }
    if ($approvedStates.Count -gt 0) {
        $approvedStates | ConvertTo-Json -Depth 3 |
            Set-Content -LiteralPath (Join-Path $backup 'approved-state.json') -Encoding UTF8
    }

    foreach ($item in $StartupItems) {
        $destination = Join-Path $backup $item.Folder.Backup
        if (-not (Test-Path -LiteralPath $destination)) {
            New-Item -Path $destination -ItemType Directory -Force | Out-Null
        }
        try {
            Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warning ("Could not back up {0}: {1}" -f $item.Name, $_.Exception.Message)
        }
    }

    $states = @($UwpTasks | Where-Object { $_.State -in 2, 4 } | ForEach-Object {
        [pscustomobject]@{ Path = $_.Key; State = $_.State; Name = $_.Name }
    })
    if ($states.Count -gt 0) {
        $states | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $backup 'uwp-startup.json') -Encoding UTF8
    }

    [pscustomobject]@{
        Timestamp = $timestamp
        Keep = $script:KeepPatterns
        UwpTasks = $states.Count
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backup 'backup.json') -Encoding UTF8

    return $backup
}

function Disable-Startup {
    param(
        [object[]]$RunEntries,
        [object[]]$StartupItems,
        [object[]]$UwpTasks,
        [string]$BackupPath
    )

    $approvedBytes = New-Object byte[] 12
    $approvedBytes[0] = 3
    [BitConverter]::GetBytes((Get-Date).ToUniversalTime().ToFileTime()).CopyTo($approvedBytes, 4)

    $runCount = 0
    foreach ($entry in $RunEntries) {
        if ($entry.Keep) { continue }

        $targets = @($entry.Source.Approved)
        if ($entry.Source.ExtraApproved) { $targets += $entry.Source.ExtraApproved }

        foreach ($target in $targets) {
            if (-not (Test-Path -LiteralPath $target)) {
                New-Item -Path $target -Force | Out-Null
            }
            New-ItemProperty -Path $target -Name $entry.Name -Value $approvedBytes -PropertyType Binary -Force | Out-Null
        }

        if ($Remove) {
            Remove-ItemProperty -Path $entry.Source.Key -Name $entry.Name -Force -ErrorAction SilentlyContinue
            foreach ($target in $targets) {
                Remove-ItemProperty -Path $target -Name $entry.Name -Force -ErrorAction SilentlyContinue
            }
        }
        $runCount++
    }

    $folderCount = 0
    foreach ($item in $StartupItems) {
        if ($item.Keep) { continue }
        $destination = Join-Path $BackupPath $item.Folder.Backup
        if (-not (Test-Path -LiteralPath $destination)) {
            New-Item -Path $destination -ItemType Directory -Force | Out-Null
        }
        $backupFile = Join-Path $destination $item.Name
        if (-not (Test-Path -LiteralPath $backupFile)) {
            Write-Warning ("Skipping {0}: backup is missing" -f $item.Name)
            continue
        }
        try {
            Move-Item -LiteralPath $item.FullName -Destination $destination -Force -ErrorAction Stop
            $folderCount++
        } catch {
            Write-Warning ("Could not move {0}: {1}" -f $item.Name, $_.Exception.Message)
        }
    }

    $uwpCount = 0
    foreach ($task in $UwpTasks) {
        if ($task.Keep -or $task.State -in 0, 1, 3) { continue }
        Set-ItemProperty -LiteralPath $task.Key -Name State -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        $uwpCount++
    }

    Write-Host ''
    Write-Host ("Disabled {0} Run entr{1}, moved {2} startup item{3}, disabled {4} packaged task{5}." -f `
        $runCount, $(if ($runCount -eq 1) { 'y' } else { 'ies' }),
        $folderCount, $(if ($folderCount -eq 1) { '' } else { 's' }),
        $uwpCount, $(if ($uwpCount -eq 1) { '' } else { 's' })) -ForegroundColor Green
    if ($Remove) {
        Write-Host 'Run values were removed after backup. Restore with -Restore.' -ForegroundColor Yellow
    } else {
        Write-Host 'Run values were disabled through StartupApproved, like Task Manager.' -ForegroundColor Yellow
    }
    Write-Host ("Backup: {0}" -f $BackupPath)
}

function Restore-Startup {
    if (-not (Test-Path -LiteralPath $backupRoot)) {
        Write-Host 'No autostart backup found.' -ForegroundColor Yellow
        return
    }

    $backup = Get-ChildItem -LiteralPath $backupRoot -Directory |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if (-not $backup) {
        Write-Host 'No autostart backup found.' -ForegroundColor Yellow
        return
    }

    Write-Host ("Restoring {0} ..." -f $backup.FullName)
    foreach ($file in Get-ChildItem -LiteralPath $backup.FullName -Filter '*.reg' -File -ErrorAction SilentlyContinue) {
        & reg.exe import $file.FullName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning ("Could not import {0}" -f $file.Name)
        }
    }

    foreach ($folder in Get-StartupFolders) {
        $source = Join-Path $backup.FullName $folder.Backup
        if (-not (Test-Path -LiteralPath $source) -or -not $folder.Path) {
            continue
        }
        if (-not (Test-Path -LiteralPath $folder.Path)) {
            New-Item -Path $folder.Path -ItemType Directory -Force | Out-Null
        }
        Get-ChildItem -LiteralPath $source -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $folder.Path -Force -ErrorAction SilentlyContinue
        }
    }

    $uwpFile = Join-Path $backup.FullName 'uwp-startup.json'
    if (Test-Path -LiteralPath $uwpFile) {
        $states = Get-Content -LiteralPath $uwpFile -Raw | ConvertFrom-Json
        foreach ($entry in @($states)) {
            if (Test-Path -LiteralPath $entry.Path) {
                Set-ItemProperty -LiteralPath $entry.Path -Name State -Value $entry.State -Type DWord -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $approvedFile = Join-Path $backup.FullName 'approved-state.json'
    if (Test-Path -LiteralPath $approvedFile) {
        $states = Get-Content -LiteralPath $approvedFile -Raw | ConvertFrom-Json
        foreach ($entry in @($states)) {
            if (-not (Test-Path -LiteralPath $entry.Path)) {
                New-Item -Path $entry.Path -Force | Out-Null
            }
            if ($null -eq $entry.Value) {
                Remove-ItemProperty -Path $entry.Path -Name $entry.Name -Force -ErrorAction SilentlyContinue
            } else {
                $bytes = [Convert]::FromBase64String($entry.Value)
                Set-ItemProperty -Path $entry.Path -Name $entry.Name -Value $bytes -Type Binary -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Host 'Restore complete. Sign out or reboot to apply.' -ForegroundColor Green
}

$runEntries = @(Get-RunEntries)
$startupItems = @(Get-StartupItems)
$uwpTasks = @(Get-UwpStartupTasks)

if ($List -or $DryRun) {
    Show-List -RunEntries $runEntries -StartupItems $startupItems -UwpTasks $uwpTasks
    if ($DryRun) {
        Write-Host ''
        Write-Host 'Dry run: nothing was changed.' -ForegroundColor Yellow
    }
    return
}

if ($Restore) {
    Restore-Startup
    return
}

$actionable = @(
    $runEntries | Where-Object { -not $_.Keep }
) + @(
    $startupItems | Where-Object { -not $_.Keep }
) + @(
    $uwpTasks | Where-Object { -not $_.Keep -and $_.State -in 2, 4 }
)

if ($actionable.Count -eq 0) {
    Write-Host 'No non-essential startup entries found.' -ForegroundColor Green
    return
}

$backup = Backup-State -RunEntries $runEntries -StartupItems $startupItems -UwpTasks $uwpTasks
Show-List -RunEntries $runEntries -StartupItems $startupItems -UwpTasks $uwpTasks
Disable-Startup -RunEntries $runEntries -StartupItems $startupItems -UwpTasks $uwpTasks -BackupPath $backup