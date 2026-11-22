# Windows VM inventory command reference

Guest: `win11-stock` — Windows 11 build 26300 (26H1) — host: NixOS 25.05,
QEMU 9.2.4, libvirt 11.4.0.  This document records the **read-only commands**
used from the NixOS host and through the SSH jump to inspect the guest.  It is
the reproducibility companion to
[`windows-memory-analysis.md`](windows-memory-analysis.md).

No password is recorded.  From the repository root on the Mac/host:

```bash
./scripts/win-ssh.sh
# equivalent:
ssh -J nixos@192.168.178.5 Windows-PC@192.168.122.50
```

The libvirt URI is explicit; plain `virsh` uses the per-user session and will not
see the domain:

```bash
virsh -c qemu:///system <command> win11-stock
```

Guest commands below are PowerShell (the Windows OpenSSH default shell).  Host
commands are bash.  Use single quotes around PowerShell so the local shell does
not expand `$`.

## Host side

### VM state and resources

```bash
virsh -c qemu:///system list --all
virsh -c qemu:///system domstate win11-stock --reason
virsh -c qemu:///system dominfo win11-stock
virsh -c qemu:///system dommemstat win11-stock
virsh -c qemu:///system domstats win11-stock --state --cpu-total --balloon \
  --block --interface
virsh -c qemu:///system vcpuinfo win11-stock
virsh -c qemu:///system dumpxml win11-stock
virsh -c qemu:///system dumpxml --inactive win11-stock
```

`dominfo` gives the configured vCPU/memory state; `dommemstat` reports the
QEMU `rss` (and balloon counters when a balloon exists); `vcpuinfo` shows which
vCPUs the guest actually runs.  `dumpxml` is the source for `<topology>`,
`<memballoon>`, graphics, disks and network.

### Disks, network and media

```bash
virsh -c qemu:///system domblklist win11-stock
virsh -c qemu:///system domifaddr win11-stock --source lease
virsh -c qemu:///system net-info default
virsh -c qemu:///system net-dhcp-leases default
virsh -c qemu:///system dumpxml win11-stock | grep -E 'source file|source network|video|graphics'
```

### Host memory, CPU and KSM

```bash
free -m
awk '/MemTotal|MemAvailable|SwapTotal|KSM/ {print}' /proc/meminfo
ps -o pid,rss,vsz,etime,args -C qemu-system-x86_64
ps aux | grep '[q]emu-system' | awk '{printf "pid=%s rss_kb=%s\n", $2, $6}'
cat /sys/kernel/mm/ksm/run
grep -E 'pages_shared|pages_sharing|pages_unshared|pages_volatile' \
  /sys/kernel/mm/ksm/*
```

The repository helper does the same summary without writing anything:

```bash
./scripts/vm-stats.sh win11-stock
```

`scripts/vm-memory.sh` is **not** read-only; it stops the guest and changes the
memory allocation.

## Guest side

### OS, CPU and memory

```powershell
Get-CimInstance Win32_OperatingSystem |
  Select-Object TotalVisibleMemorySize,FreePhysicalMemory,
                TotalVirtualMemorySize,FreeVirtualMemory,
                SizeStoredInPagingFiles,FreeSpaceInPagingFiles
Get-CimInstance Win32_ComputerSystem |
  Select-Object Manufacturer,Model,NumberOfLogicalProcessors,NumberOfProcessors,TotalPhysicalMemory
Get-CimInstance Win32_Processor |
  Select-Object Name,NumberOfCores,NumberOfLogicalProcessors
Get-CimInstance Win32_PerfRawData_PerfOS_Memory |
  Select-Object CommittedBytes,CommitLimit,AvailableBytes,CacheBytes,PoolPagedBytes,PoolNonpagedBytes
Get-CimInstance Win32_PageFileUsage
Get-MMAgent
Get-ComputerInfo | Select-Object WindowsProductName,WindowsVersion,OsBuildNumber
(Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
qwinsta
```

`Win32_Processor` showing two one-core sockets while `vcpuinfo` shows six is how
the Windows client two-socket limit was found.

### Processes

```powershell
Get-Process |
  Select-Object Id,ProcessName,SessionId,WorkingSet64,PrivateMemorySize64,CPU,Path |
  Sort-Object WorkingSet64 -Descending |
  ConvertTo-Csv -NoTypeInformation
Get-CimInstance Win32_Process |
  Select-Object ProcessId,ParentProcessId,ExecutablePath,CommandLine
Get-Process | Group-Object SessionId |
  ForEach-Object { [pscustomobject]@{
    Session=$_.Name; Count=$_.Count
    WS_MB=[math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum)/1MB,0)
  }}
Get-Process | Measure-Object WorkingSet64 -Sum
```

The CSV is the raw data behind the appendix in the memory analysis.  Working
sets are not additive because shared pages are counted per process; committed
bytes are the authoritative guest figure.

### Services and service→PID mapping

```powershell
Get-CimInstance Win32_Service |
  Select-Object Name,DisplayName,State,StartMode,ProcessId,PathName
Get-CimInstance Win32_Service | Where-Object State -eq 'Running'
Get-CimInstance Win32_Service | Where-Object StartMode -eq 'Disabled'
Get-Service WSearch,SysMain,Spooler,WinDefend
Get-CimInstance Win32_Service -Filter "Name='WSearch'" |
  Select-Object Name,State,StartMode,PathName
```

Joining `Win32_Service.ProcessId` to `Get-Process.Id` gives the
`svchost` service groups and their working sets, which is how the service table
in the memory analysis was produced.

Per-user service templates are registry values, not normal services:

```powershell
Get-Service 'WpnUserService_*','CDPUserSvc_*','cbdhsvc_*','webthreatdefusersvc_*' |
  Select-Object Name,Status,StartType
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WpnUserService' |
  Select-Object Start
```

### Startup entries and scheduled tasks

```powershell
Get-CimInstance Win32_StartupCommand |
  Select-Object Name,Command,Location,User
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
Get-ItemProperty 'Registry::HKEY_USERS\S-1-5-20\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
Get-ChildItem 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup'
Get-ScheduledTask | Select-Object TaskPath,TaskName,State
Get-ScheduledTask | Where-Object State -eq 'Running'
Get-ScheduledTask | Where-Object State -eq 'Ready'
Get-ScheduledTask | ForEach-Object { $_ | Get-ScheduledTaskInfo } |
  Select-Object TaskPath,TaskName,LastRunTime,NextRunTime,LastTaskResult
```

### Security state

```powershell
Get-MpComputerStatus |
  Select-Object AMRunningMode,AMServiceEnabled,AntivirusEnabled,
                RealTimeProtectionEnabled,BehaviorMonitorEnabled,
                IoavProtectionEnabled,OnAccessProtectionEnabled,NISEnabled
Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct |
  Select-Object displayName,productState
Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard |
  Select-Object VirtualizationBasedSecurityStatus,SecurityServicesRunning,SecurityServicesConfigured
```

### Apps, features, capabilities and printers

```powershell
Get-AppxPackage |
  Select-Object Name,PackageFullName,IsFramework,NonRemovable,SignatureKind,InstallLocation
Get-AppxPackage -AllUsers |
  Select-Object Name,PackageFullName
Get-AppxProvisionedPackage -Online |
  Select-Object DisplayName,PackageName
Get-WindowsOptionalFeature -Online |
  Select-Object FeatureName,State
Get-WindowsCapability -Online |
  Select-Object Name,State
Get-Printer | Select-Object Name,DriverName,PortName
Get-PrinterDriver | Select-Object Name
Get-PrinterPort | Select-Object Name
Get-Service Spooler,Fax,PrintNotify,PrintScanBrokerService,PrintDeviceConfigurationService
```

For a specific package, include its dependency/removal metadata:

```powershell
Get-AppxPackage MicrosoftWindows.Client.CoreAI |
  Format-List Name,PackageFullName,IsFramework,NonRemovable,SignatureKind,InstallLocation,Dependencies
Get-AppxPackage | ForEach-Object {
  if ($_.Dependencies.PackageFullName -match 'AIFabric|CoreAI') {
    [pscustomobject]@{ Name=$_.Name; Deps=($_.Dependencies.PackageFullName -join ';') }
  }
}
```

`NonRemovable=True` plus `SignatureKind=System` explains the `0x80073CFA`
failures for protected inbox apps.

### AI components

```powershell
Get-Service | Where-Object {
  $_.Name -match 'Copilot|Recall|Fabric|Intelligen|Semantic|ClickToDo|CoreAI|WindowsAI' -or
  $_.DisplayName -match 'Copilot|Recall|Fabric|Intelligen|Semantic|ClickToDo|CoreAI|Windows AI'
}
Get-Process | Where-Object {
  $_.ProcessName -match 'Copilot|Recall|Fabric|Intelligen|Semantic|ClickToDo|CoreAI|WindowsAI' -or
  $_.Path -match 'Copilot|Recall|Fabric|Intelligen|Semantic|ClickToDo|CoreAI|WindowsAI'
}
Get-AppxPackage | Where-Object {
  $_.Name -match 'AIFabric|Copilot|Recall|Intelligen|Semantic|ClickToDo|CoreAI|WindowsAI|Windows\.AI'
}
Get-AppxProvisionedPackage -Online | Where-Object {
  $_.PackageName -match 'AIFabric|Copilot|Recall|Intelligen|Semantic|ClickToDo|CoreAI|WindowsAI' -or
  $_.DisplayName -match 'AIFabric|Copilot|Recall|Intelligen|Semantic|ClickToDo|CoreAI|Windows AI'
}
Get-ScheduledTask | Where-Object {
  $_.TaskPath -like '\Microsoft\Windows\WindowsAI\*' -or
  $_.TaskName -match 'Copilot|Recall|AIFabric|WindowsAI|ClickToDo|Semantic|Intelligen'
}
Get-WindowsOptionalFeature -Online |
  Where-Object { $_.FeatureName -match 'Copilot|Recall|AIFabric|WindowsAI|Semantic|ClickToDo|Intelligen' }
```

Registry checks used for the AI policy audit:

```powershell
'Policies\Microsoft\Windows\WindowsAI',
'Policies\Microsoft\Windows\WindowsCopilot',
'Microsoft\Windows\CurrentVersion\Policies\Paint',
'Policies\WindowsNotepad',
'Policies\Microsoft\Edge' |
  ForEach-Object {
    $path = "HKLM:\SOFTWARE\$($_)"
    if (Test-Path $path) { Get-ItemProperty $path | Format-List }
  }
Get-ItemProperty 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' -ErrorAction SilentlyContinue
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced',
                 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' |
  Select-Object PSPath,ShowCopilotButton
```

### Launcher, guards and helper tasks

```powershell
Get-Process PowerToys*,Microsoft.CmdPal*,Everything,StartMenuExperienceHost
Get-Service Everything,WSearch
Get-Service PowerToys*
Get-Content "$env:LOCALAPPDATA\Microsoft\PowerToys\settings.json" -Raw
Get-Content "$env:LOCALAPPDATA\Microsoft\PowerToys\PowerToys Run\settings.json" -Raw
Get-ScheduledTask -TaskPath '\WindowsSlim\' | Select-Object TaskPath,TaskName,State
Get-WmiObject -Namespace root\subscription -Class __EventFilter |
  Select-Object Name,Query
Get-WmiObject -Namespace root\subscription -Class __FilterToConsumerBinding |
  Select-Object Filter,Consumer
Test-Path 'C:\Windows\SystemApps\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\StartMenuExperienceHost.exe'
Test-Path 'C:\Windows\SystemApps\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\StartMenuExperienceHost.exe.disabled'
```

### One-shot raw snapshot

A single SSH invocation can collect processes, services and memory as one CSV
block, which avoids mixing multiple transient SSH/WMI helper processes:

```bash
./scripts/win-ssh.sh '
$os = Get-CimInstance Win32_OperatingSystem
[pscustomobject]@{
  Time=(Get-Date -Format o); Boot=$os.LastBootUpTime
  TotalMB=[math]::Round($os.TotalVisibleMemorySize/1024,0)
  FreeMB=[math]::Round($os.FreePhysicalMemory/1024,0)
  CommitGB=[math]::Round((Get-CimInstance Win32_PerfRawData_PerfOS_Memory).CommittedBytes/1GB,2)
  ProcCount=(Get-Process).Count
  WSSumMB=[math]::Round(((Get-Process | Measure-Object WorkingSet64 -Sum).Sum/1MB),0)
} | ConvertTo-Csv -NoTypeInformation
Get-Process | Select-Object Id,ProcessName,SessionId,
  @{n="WS_MB";e={[math]::Round($_.WorkingSet64/1MB,1)}},
  @{n="Private_MB";e={[math]::Round($_.PrivateMemorySize64/1MB,1)}},Path |
  ConvertTo-Csv -NoTypeInformation
Get-CimInstance Win32_Service | Select-Object Name,ProcessId,State,StartMode |
  ConvertTo-Csv -NoTypeInformation
'
```

### Notes

- The snapshot includes the SSH session itself (`sshd`, `powershell`,
  `conhost`) and transient WMI providers (`WmiPrvSE`, `WmiApSrv`); mark or
  exclude them when comparing idle states.
- Working sets double-count shared DLLs; use `CommittedBytes` for the guest’s
  real memory footprint and working sets for ranking.
- German locale output uses decimal commas in CSV (`"283,1"`); normalize before
  parsing.
- The `virsh` commands are read-only.  The registry/policy and service commands
  in the memory/AI documents are not; they are listed there with rollback.