$ErrorActionPreference = 'Continue'
Write-Host 'Enabling TRIM ...'
fsutil behavior set DisableDeleteNotify 0

Write-Host 'High performance power plan ...'
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

Write-Host 'Disabling hibernation/Fast Startup ...'
powercfg /hibernate off

Write-Host ''
fsutil behavior query DisableDeleteNotify
powercfg /getactivescheme
