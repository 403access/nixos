$ErrorActionPreference = 'Stop'
Write-Host 'Enabling System Restore on C: ...'
Enable-ComputerRestore -Drive 'C:\'
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' `
  -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force | Out-Null
Write-Host 'Creating checkpoint (this can take a minute) ...'
Checkpoint-Computer -Description 'Before debloat' -RestorePointType 'MODIFY_SETTINGS'
Get-ComputerRestorePoint | Format-Table SequenceNumber, Description, CreationTime -AutoSize
vssadmin list shadowstorage
