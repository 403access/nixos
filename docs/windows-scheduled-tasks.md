# Windows 11 scheduled tasks: inventory and necessity analysis

Guest: `win11-stock` — Windows 11 build 26300 (26H1) — exported 2026-11-21.

This document inventories the scheduled tasks registered in the guest, explains what each one does, and recommends whether it is needed for the documented role: a **minimal Windows 11 developer VM reached over RDP/SSH**, used for browser/Office work, with printing and Bluetooth optional and Defender/Search configurable.

## Bottom line

- **247 normal active definitions** have complete XML metadata. 189 are explicitly enabled and 58 are explicitly disabled.
- **4 Defender task definitions** exist only as `.bak` backups; their registered task entries have no readable XML.
- **37 registry-only paths** are registered in `TaskCache` but have no XML definition on disk. Their live state cannot be read offline.
- Of the 247 normal definitions: **84 Keep**, **116 Optional**, **47 Disable**, **0 Review**.
- Of the 37 registry-only paths: **14 Keep**, **19 Optional**, **4 Disable**, **0 Review** — check these live.
- The existing [`disable-scheduled-tasks.ps1`](../scripts/windows/disable-scheduled-tasks.ps1) already covers the main telemetry/compatibility folders, including the SQM task under `PI`. The additional safe candidates are mostly **Diagnosis, Flighting, WindowsAI, Sustainability, UsageAndQualityInsights, PerformanceTrace, AccountHealth, ConsentUX, and Speech**.
- **Do not bulk-disable** Windows Update/servicing, Defender (if you keep it on), time sync, storage health, TPM/certificate maintenance, licensing, firewall, or recovery.

## How this was produced

1. The Windows disk was mounted offline and `C:\Windows\System32\Tasks` was copied.
2. The Task Scheduler cache was exported from `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache`.
3. Each XML definition was parsed for its URI, description, triggers, actions, principal and `<Settings><Enabled>` value.
4. A task is counted as **active** when it has a normal XML definition and a matching `TaskCache\Tree` registration. The `.bak` Defender files and the registry-only paths are reported separately.

The export is read-only; no task was run, enabled or disabled. Windows paths are case-insensitive, so matching ignores case.

### Definitions used below

| Verdict | Meaning |
| --- | --- |
| **Keep** | Core Windows function. Leave it as Windows set it; do not disable or delete it. A “currently disabled” note means Windows ships it disabled and that is normal. |
| **Optional** | Feature-specific. Disabling it is safe if you do not use that feature. |
| **Disable** | Safe to turn off for this VM; it is telemetry, consumer content, diagnostics, or an unused feature. |
| **Review** | The offline data is insufficient; check the live task before changing it. |
| **Backup (.bak)** | A task definition was renamed to `.bak`; the registered entry has no readable XML. Leave it unless you are repairing Defender. |

**State** comes from the task XML’s `<Settings><Enabled>` value. “Unknown” means the task is registered but has no XML on disk. This is not the same as the live `Get-ScheduledTask` state, which also reflects policy and protected-task behavior.

## Summary by category

Counts are for the 247 normal active definitions; special cases are listed separately.

| Category | Tasks | Keep | Optional | Disable | Review |
| --- | ---: | ---: | ---: | ---: | ---: |
| Windows Update & servicing | 28 | 28 | 0 | 0 | 0 |
| Security, identity & attestation | 37 | 13 | 23 | 1 | 0 |
| Time, language & licensing | 16 | 16 | 0 | 0 | 0 |
| Storage health & maintenance | 25 | 10 | 15 | 0 | 0 |
| App compatibility & runtime | 4 | 0 | 4 | 0 | 0 |
| Apps, Store & AI | 26 | 10 | 9 | 7 | 0 |
| Devices, drivers & hardware | 20 | 5 | 15 | 0 | 0 |
| Networking & sync | 18 | 1 | 17 | 0 | 0 |
| Shell, input & management | 31 | 1 | 30 | 0 | 0 |
| Telemetry, feedback & diagnostics | 40 | 0 | 2 | 38 | 0 |
| Optional consumer & third-party | 2 | 0 | 1 | 1 | 0 |
| **Total** | **247** | **84** | **116** | **47** | **0** |

### Special cases

| Group | Count | Why it is separate |
| --- | ---: | --- |
| Defender `.bak` definitions | 4 | Registered Defender tasks whose XML files were renamed to `.bak`. |
| Registry-only paths | 37 | A `TaskCache\Tree` entry exists, but no XML definition was found. |

## Detailed inventory

Tasks are grouped by category and then by their Task Scheduler folder. The full path is the folder line plus the task name, for example `\Microsoft\Windows\Time Synchronization\SynchronizeTime`.

### Windows Update & servicing

**`\Microsoft\Windows\InstallService`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `RestoreDevice` | Enabled | Restores update-related device state after a failed install. | On system event | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |
| `ScanForUpdates` | Enabled | Scans for updates through the Windows InstallService. | Daily / On system event | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |
| `ScanForUpdatesAsUser` | Enabled | Runs an update scan in the user context. | Manual/on-demand | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |
| `SmartRetry` | Enabled | Retries failed update installations. | No active trigger | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |
| `WakeUpAndContinueUpdates` | Disabled | Wakes the device to continue pending updates. | Manual/on-demand | **Keep** — Currently disabled by Windows; leave the default. |
| `WakeUpAndScanForUpdates` | Disabled | Wakes the device to scan for updates. | Daily | **Keep** — Currently disabled by Windows; leave the default. |

**`\Microsoft\Windows\RecoveryEnvironment`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `VerifyWinRE` | Enabled | Verifies the Windows Recovery Environment. | Manual/on-demand | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |

**`\Microsoft\Windows\Servicing`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `OOBEFodSetup` | Disabled | Installs Features on Demand needed during OOBE. | On system event | **Keep** — Currently disabled by Windows; leave the default. |
| `StartComponentCleanup` | Enabled | Cleans up superseded Windows component versions (WinSxS). | Manual/on-demand | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |

**`\Microsoft\Windows\Setup`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `PITRTask` | Enabled | Point-in-time restore/setup recovery maintenance. | At boot | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |
| `SetupCleanupTask` | Enabled | Removes temporary Windows Setup files after installation. | Every 5 days | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |
| `SetupRecoveryDataTask` | Enabled | Maintains recovery data used by Windows Setup. | Every 14 days | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |

**`\Microsoft\Windows\StateRepository`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `MaintenanceTasks` | Enabled | Maintains the State Repository database. | Manual/on-demand | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |

**`\Microsoft\Windows\UpdateOrchestrator`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Report policies` | Enabled | Reports update policy state to the Update Orchestrator. | On system event | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |
| `Schedule Maintenance Work` | Disabled | Coordinates update work with the maintenance window. | Manual/on-demand | **Keep** — Currently disabled by Windows; leave the default. |
| `Schedule Scan` | Enabled | Schedules Windows Update scans and downloads. | Every 1320 min | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |
| `Schedule Scan Static Task` | Enabled | Runs a static scheduled Windows Update scan. | On system event / On event | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |
| `Schedule Wake To Work` | Disabled | Wakes the PC to run scheduled update work. | Manual/on-demand | **Keep** — Currently disabled by Windows; leave the default. |
| `Schedule Work` | Enabled | Runs queued Windows Update work during maintenance windows. | Once | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |
| `Start Oobe Expedite Work` | Enabled | Expedites post-OOBE update work. | On system event | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |
| `StartOobeAppsScan_LicenseAccepted` | Enabled | Scans for post-OOBE app updates. | On system event | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |
| `StartOobeAppsScanAfterUpdate` | Enabled | Scans for post-OOBE app updates. | On system event | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |
| `UIEOrchestrator` | Enabled | Orchestrates update UX and reboot prompts. | Daily | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |
| `USO_UxBroker` | Enabled | Shows Windows Update orchestration UI/notifications. | On system event / Daily | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |
| `UUS Failover Task` | Enabled | Fallback path for Update Orchestrator when the normal service is unavailable. | On system event | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |

**`\Microsoft\Windows\WaaSMedic`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `PerformRemediation` | Disabled | Repairs Windows Update components when the servicing stack detects a problem. | Every 7 days | **Keep** — Currently disabled by Windows; leave the default. |

**`\Microsoft\Windows\WindowsUpdate`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Refresh Group Policy Cache` | Enabled | Refreshes the cached Windows Update group policy. | On system event | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |
| `Scheduled Start` | Enabled | Starts the Windows Update scan/install cycle on its schedule. | Once | **Keep** — Keeps Windows patched, serviced, or recoverable; leave enabled. |

### Security, identity & attestation

**`\Microsoft\Windows\Active Directory Rights Management Services Client`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `AD RMS Rights Policy Template Management (Automated)` | Disabled | Updates AD RMS rights-policy templates automatically. | Daily / At logon | **Optional** — currently disabled; enable only if you use this feature. Only needed if this machine uses AD RMS rights-policy templates. |
| `AD RMS Rights Policy Template Management (Manual)` | Enabled | Updates AD RMS rights-policy templates on demand. | No active trigger | **Optional** — Only needed if this machine uses AD RMS rights-policy templates. |

**`\Microsoft\Windows\AppID`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `EDP Policy Manager` | Enabled | Applies Enterprise Data Protection app policy. | On system event | **Optional** — Enterprise Data Protection app policy; not used in a standalone VM. |
| `PolicyConverter` | Enabled | Converts legacy AppID policy settings. | Manual/on-demand | **Keep** — Security/identity function; leave enabled. |
| `VerifiedPublisherCertStoreCheck` | Enabled | Checks the verified-publisher certificate store. | At boot | **Keep** — Security/identity function; leave enabled. |

**`\Microsoft\Windows\BitLocker`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `BitLocker Encrypt All Drives` | Enabled | Starts BitLocker encryption for all drives when policy requires it. | On system event | **Optional** — Only needed if you use BitLocker on this VM. |
| `BitLocker MDM policy Refresh` | Enabled | Refreshes BitLocker MDM policy. | On system event | **Optional** — Only needed if you use BitLocker on this VM. |

**`\Microsoft\Windows\CertificateServicesClient`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `AIKCertEnrollTask` | Enabled | Enrolls a TPM attestation (AIK) certificate. | On system event / Once | **Keep** — Security/identity function; leave enabled. |
| `CryptoPolicyTask` | Enabled | Applies certificate/crypto policy. | On system event | **Keep** — Security/identity function; leave enabled. |
| `KeyPreGenTask` | Enabled | Pre-generates cryptographic keys. | On system event | **Keep** — Security/identity function; leave enabled. |
| `SystemTask` | Enabled | Runs certificate-services maintenance for the system account. | On system event / On registration / At boot | **Keep** — Security/identity function; leave enabled. |
| `UserTask` | Enabled | Runs certificate-services maintenance for the user. | On system event / On registration / At logon / On event | **Keep** — Security/identity function; leave enabled. |
| `UserTask-Roam` | Enabled | Roams user certificates. | On session change | **Keep** — Security/identity function; leave enabled. |

**`\Microsoft\Windows\Device Information`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Device` | Enabled | Collects device information for the system. | Daily | **Optional** — Device inventory/telemetry; not needed. |
| `Device User` | Enabled | Collects device information for the user. | At logon | **Optional** — Device inventory/telemetry; not needed. |

**`\Microsoft\Windows\DeviceDirectoryClient`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `HandleCommand` | Enabled | Device-directory registration/maintenance. | On system event | **Optional** — Device-directory registration; not needed standalone. |
| `HandleWnsCommand` | Enabled | Device-directory registration/maintenance. | On system event | **Optional** — Device-directory registration; not needed standalone. |
| `IntegrityCheck` | Enabled | Device-directory registration/maintenance. | Every 6 days | **Optional** — Device-directory registration; not needed standalone. |
| `LocateCommandUserSession` | Enabled | Device-directory registration/maintenance. | On system event | **Optional** — Device-directory registration; not needed standalone. |
| `RegisterDeviceAccountChange` | Enabled | Device-directory registration/maintenance. | On system event | **Optional** — Device-directory registration; not needed standalone. |
| `RegisterDeviceLocationRightsChange` | Disabled | Device-directory registration/maintenance. | On system event | **Optional** — currently disabled; enable only if you use this feature. Device-directory registration; not needed standalone. |
| `RegisterDevicePeriodic24` | Disabled | Device-directory registration/maintenance. | Every 16 hours | **Optional** — currently disabled; enable only if you use this feature. Device-directory registration; not needed standalone. |
| `RegisterDevicePolicyChange` | Enabled | Device-directory registration/maintenance. | On system event | **Optional** — Device-directory registration; not needed standalone. |
| `RegisterDeviceProtectionStateChanged` | Enabled | Device-directory registration/maintenance. | On system event | **Optional** — Device-directory registration; not needed standalone. |
| `RegisterDeviceSettingChange` | Enabled | Device-directory registration/maintenance. | On system event | **Optional** — Device-directory registration; not needed standalone. |
| `RegisterUserDevice` | Enabled | Device-directory registration/maintenance. | At logon / On system event | **Optional** — Device-directory registration; not needed standalone. |

**`\Microsoft\Windows\EDP`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `EDP App Launch Task` | Enabled | Enterprise Data Protection app-launch check. | On system event | **Optional** — Enterprise Data Protection; not used in a standalone VM. |
| `EDP Auth Task` | Enabled | Enterprise Data Protection authentication check. | On system event | **Optional** — Enterprise Data Protection; not used in a standalone VM. |
| `EDP Inaccessible Credentials Task` | Enabled | Enterprise Data Protection credential check. | On system event | **Optional** — Enterprise Data Protection; not used in a standalone VM. |
| `StorageCardEncryption Task` | Enabled | Enterprise Data Protection storage-card encryption. | On system event | **Optional** — Enterprise Data Protection; not used in a standalone VM. |

**`\Microsoft\Windows\ExploitGuard`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `ExploitGuard MDM policy Refresh` | Enabled | Refreshes Exploit Guard MDM policy. | On system event / At boot | **Keep** — Security/identity function; leave enabled. |

**`\Microsoft\Windows\PI`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Secure-Boot-Update` | Disabled | Applies Secure Boot DBX/update policy. | At boot | **Keep** — Currently disabled by Windows; leave the default. |
| `Sqm-Tasks` | Disabled | Collects software inventory/SQM telemetry. | Manual/on-demand | **Disable** — already disabled; no action needed. SQM/software inventory telemetry; not needed on a dev VM. |

**`\Microsoft\Windows\Pluton`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Pluton-Ksp-Provisioning` | Enabled | Provisions the Pluton security-processor key-storage provider. | On system event | **Optional** — Pluton security-processor provisioning; this VM uses a vTPM, not Pluton. |

**`\Microsoft\Windows\TPM`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Tpm-HASCertRetr` | Enabled | Retrieves TPM health-attestation certificates. | On system event | **Keep** — Security/identity function; leave enabled. |
| `Tpm-Maintenance` | Enabled | Maintains TPM provisioning and health. | On system event | **Keep** — Security/identity function; leave enabled. |
| `Tpm-PreAttestationHealthCheck` | Enabled | Runs a TPM pre-attestation health check. | On system event | **Keep** — Security/identity function; leave enabled. |

### Time, language & licensing

**`\Microsoft\Windows\Clip`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `License Validation` | Disabled | Clip/ESU subscription licensing task. | No active trigger | **Keep** — Currently disabled by Windows; leave the default. |
| `LicenseImdsIntegration` | Disabled | Clip/ESU subscription licensing task. | At logon / Daily / On system event | **Keep** — Currently disabled by Windows; leave the default. |

**`\Microsoft\Windows\International`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Synchronize Language Settings` | Enabled | Applies language settings across the system. | On system event / At logon | **Keep** — Clock, language, or licensing function; leave enabled. |

**`\Microsoft\Windows\LanguageComponentsInstaller`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Installation` | Enabled | Installs language components. | At logon | **Keep** — Clock, language, or licensing function; leave enabled. |
| `ReconcileLanguageResources` | Enabled | Reconciles installed language resources. | At logon | **Keep** — Clock, language, or licensing function; leave enabled. |
| `Uninstallation` | Enabled | Removes language components. | Manual/on-demand | **Keep** — Clock, language, or licensing function; leave enabled. |

**`\Microsoft\Windows\License Manager`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `TempSignedLicenseExchange` | Enabled | Exchanges temporary signed licenses for activation. | Manual/on-demand | **Keep** — Clock, language, or licensing function; leave enabled. |

**`\Microsoft\Windows\MUI`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `LPRemove` | Enabled | Removes language packs. | Manual/on-demand | **Keep** — Clock, language, or licensing function; leave enabled. |

**`\Microsoft\Windows\SoftwareProtectionPlatform`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `SvcRestartTask` | Enabled | Restarts the Software Protection service if needed. | Daily | **Keep** — Clock, language, or licensing function; leave enabled. |
| `SvcRestartTaskLogon` | Disabled | Restarts Software Protection at logon if needed. | At logon | **Keep** — Currently disabled by Windows; leave the default. |
| `SvcRestartTaskNetwork` | Disabled | Restarts Software Protection when the network becomes available. | On event | **Keep** — Currently disabled by Windows; leave the default. |

**`\Microsoft\Windows\Subscription`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `EnableLicenseAcquisition` | Enabled | Enables subscription license acquisition. | On event / On system event | **Keep** — Clock, language, or licensing function; leave enabled. |
| `LicenseAcquisition` | Disabled | Acquires subscription licenses. | Daily / On registration / On system event | **Keep** — Currently disabled by Windows; leave the default. |

**`\Microsoft\Windows\Time Synchronization`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `ForceSynchronizeTime` | Enabled | Forces an immediate w32time synchronization after boot or network changes. | On system event | **Keep** — Clock, language, or licensing function; leave enabled. |
| `SynchronizeTime` | Enabled | Keeps the guest clock in sync with the configured time source via w32time. | On system event | **Keep** — Clock, language, or licensing function; leave enabled. |

**`\Microsoft\Windows\Time Zone`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `SynchronizeTimeZone` | Enabled | Updates the system time zone when location or policy changes. | Manual/on-demand | **Keep** — Clock, language, or licensing function; leave enabled. |

### Storage health & maintenance

**`\Microsoft\Windows\Chkdsk`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `ProactiveScan` | Enabled | Scans the system volume for file-system problems proactively. | Manual/on-demand | **Keep** — Storage health/maintenance; leave enabled. |
| `SyspartRepair` | Enabled | Repairs the system partition when corruption is detected. | On system event | **Keep** — Storage health/maintenance; leave enabled. |

**`\Microsoft\Windows\CloudRestore`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Backup` | Enabled | Runs cloud-backup maintenance. | On system event / Every 8 days | **Optional** — Cloud backup/restore maintenance; not used. |
| `Restore` | Enabled | Runs cloud-restore maintenance. | On system event | **Optional** — Cloud backup/restore maintenance; not used. |

**`\Microsoft\Windows\Data Integrity Scan`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Data Integrity Check And Scan` | Enabled | Runs a full data-integrity check and scan. | No active trigger | **Keep** — Storage health/maintenance; leave enabled. |
| `Data Integrity Scan` | Enabled | Scans storage for integrity errors. | Manual/on-demand | **Keep** — Storage health/maintenance; leave enabled. |
| `Data Integrity Scan for Crash Recovery` | Enabled | Checks storage integrity after a crash. | On system event | **Keep** — Storage health/maintenance; leave enabled. |

**`\Microsoft\Windows\Defrag`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `ScheduledDefrag` | Enabled | Runs the scheduled defrag/TRIM optimization pass on storage. | Manual/on-demand | **Keep** — Storage health/maintenance; leave enabled. |

**`\Microsoft\Windows\DiskCleanup`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `SilentCleanup` | Enabled | Runs Disk Cleanup silently when free space is low. | Manual/on-demand | **Keep** — Storage health/maintenance; leave enabled. |

**`\Microsoft\Windows\DiskFootprint`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Diagnostics` | Enabled | Collects storage footprint diagnostics. | Manual/on-demand | **Optional** — Storage diagnostic snapshot; keep only while troubleshooting disk usage. |
| `StorageSense` | Enabled | Runs Storage Sense cleanup rules. | Manual/on-demand | **Keep** — Storage health/maintenance; leave enabled. |

**`\Microsoft\Windows\File Classification Infrastructure`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Property Definition Sync` | Disabled | Syncs file-classification property definitions. | Daily | **Optional** — currently disabled; enable only if you use this feature. Only needed if you use file-classification rules. |

**`\Microsoft\Windows\ReFsDedupSvc`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Initialization` | Enabled | Initializes ReFS deduplication. | On system event | **Optional** — Only for ReFS deduplication. |

**`\Microsoft\Windows\Registry`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `RegIdleBackup` | Enabled | Backs up registry hives while the system is idle. | Manual/on-demand | **Keep** — Storage health/maintenance; leave enabled. |

**`\Microsoft\Windows\SpacePort`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `SpaceAgentTask` | Enabled | Storage Spaces agent task. | On system event | **Optional** — Only for Storage Spaces. |
| `SpaceManagerTask` | Enabled | Storage Spaces manager task. | On system event | **Optional** — Only for Storage Spaces. |

**`\Microsoft\Windows\Storage Tiers Management`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Storage Tiers Management Initialization` | Enabled | Initializes storage-tier management. | On system event | **Optional** — Only for storage-tier volumes. |
| `Storage Tiers Optimization` | Disabled | Optimizes storage tiers. | Every 4 hours | **Optional** — currently disabled; enable only if you use this feature. Only for storage-tier volumes. |

**`\Microsoft\Windows\Sysmain`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `HybridDriveCachePrepopulate` | Disabled | Prepopulates the hybrid-drive cache. | Manual/on-demand | **Optional** — currently disabled; enable only if you use this feature. Only useful while SysMain is enabled. |
| `HybridDriveCacheRebalance` | Disabled | Rebalances the hybrid-drive cache. | Manual/on-demand | **Optional** — currently disabled; enable only if you use this feature. Only useful while SysMain is enabled. |
| `ResPriStaticDbSync` | Enabled | Syncs the SysMain static database. | Manual/on-demand | **Optional** — Only useful while SysMain is enabled. |
| `WsSwapAssessmentTask` | Enabled | Assesses working-set/swap behavior. | Manual/on-demand | **Optional** — Only useful while SysMain is enabled. |

**`\Microsoft\Windows\SystemRestore`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `SR` | Enabled | Creates periodic System Restore points. | Manual/on-demand | **Keep** — Storage health/maintenance; leave enabled. |

**`\Microsoft\Windows\WOF`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `WIM-Hash-Management` | Enabled | Manages WIM hash state. | On system event | **Optional** — WIM hash maintenance; low value. |
| `WIM-Hash-Validation` | Enabled | Validates WIM hash state. | Manual/on-demand | **Optional** — WIM hash maintenance; low value. |

### App compatibility & runtime

**`\Microsoft\Windows\.NET Framework`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `.NET Framework NGEN v4.0.30319` | Enabled | Maintains native images for .NET Framework assemblies. | Manual/on-demand | **Optional** — Maintains native images for .NET Framework assemblies; keep if you run .NET Framework apps. |
| `.NET Framework NGEN v4.0.30319 64` | Enabled | Maintains native images for .NET Framework assemblies. | Manual/on-demand | **Optional** — Maintains native images for .NET Framework assemblies; keep if you run .NET Framework apps. |
| `.NET Framework NGEN v4.0.30319 64 Critical` | Disabled | Maintains native images for .NET Framework assemblies. | When idle | **Optional** — currently disabled; enable only if you use this feature. Maintains native images for .NET Framework assemblies; keep if you run .NET Framework apps. |
| `.NET Framework NGEN v4.0.30319 Critical` | Disabled | Maintains native images for .NET Framework assemblies. | When idle | **Optional** — currently disabled; enable only if you use this feature. Maintains native images for .NET Framework assemblies; keep if you run .NET Framework apps. |

### Apps, Store & AI

**`\ (root)`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `MicrosoftEdgeUpdateTaskMachineCore{07AB5111-3768-4BB9-80D7-725B30D325F4}` | Enabled | Edge updater task. | At logon / Daily | **Optional** — Only if you use Microsoft Edge in the guest. |
| `MicrosoftEdgeUpdateTaskMachineUA{4915ED52-9F76-4DCF-BC2B-7720F7C5C6E2}` | Enabled | Edge updater task. | Daily | **Optional** — Only if you use Microsoft Edge in the guest. |
| `OneDrive Reporting Task-S-1-5-21-2627163621-65005677-2634483723-1001` | Enabled | OneDrive update/report/startup task. | Daily | **Optional** — Only if you use OneDrive in the guest. |
| `OneDrive Standalone Update Task-S-1-5-21-2627163621-65005677-2634483723-1001` | Enabled | OneDrive update/report/startup task. | Daily | **Optional** — Only if you use OneDrive in the guest. |
| `OneDrive Startup Task-S-1-5-21-2627163621-65005677-2634483723-1001` | Enabled | OneDrive update/report/startup task. | At logon | **Optional** — Only if you use OneDrive in the guest. |

**`\Microsoft\Windows\ApplicationData`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `CleanupTemporaryState` | Enabled | Cleans temporary application state. | Manual/on-demand | **Keep** — App deployment/state maintenance; leave enabled. |
| `DsSvcCleanup` | Enabled | Cleans Data Sharing Service state. | Manual/on-demand | **Keep** — App deployment/state maintenance; leave enabled. |

**`\microsoft\windows\applicationdata`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `appuriverifierdaily` | Enabled | Verifies app URI handlers. | Manual/on-demand | **Keep** — App deployment/state maintenance; leave enabled. |
| `appuriverifierinstall` | Enabled | Verifies app URI handlers. | On system event | **Keep** — App deployment/state maintenance; leave enabled. |

**`\Microsoft\Windows\AppListBackup`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Backup` | Enabled | Backs up the app list. | Manual/on-demand | **Keep** — App deployment/state maintenance; leave enabled. |
| `BackupNonMaintenance` | Enabled | Backs up the app list. | Every 14 days | **Keep** — App deployment/state maintenance; leave enabled. |

**`\Microsoft\Windows\AppxDeploymentClient`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Pre-staged app cleanup` | Disabled | Cleans up pre-staged app packages. | At logon | **Keep** — Currently disabled by Windows; leave the default. |
| `UCPD velocity` | Enabled | Cleans up pre-staged app packages. | At logon | **Keep** — App deployment/state maintenance; leave enabled. |

**`\Microsoft\Windows\BrokerInfrastructure`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `BgTaskRegistrationMaintenanceTask` | Enabled | Maintains background-task registrations. | Manual/on-demand | **Keep** — App deployment/state maintenance; leave enabled. |

**`\microsoft\windows\capabilityaccessmanager`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `maintenancetasks` | Enabled | Maintains privacy capability-access state. | Manual/on-demand | **Keep** — App deployment/state maintenance; leave enabled. |

**`\Microsoft\Windows\Containers`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `CmCleanup` | Enabled | Cleans up container state. | Manual/on-demand | **Optional** — Only needed if you run Windows containers. |

**`\Microsoft\Windows\PushToInstall`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `LoginCheck` | Enabled | Checks Store push-to-install state at logon. | At logon | **Optional** — Store push-to-install; only if you use Store apps. |
| `Registration` | Enabled | Registers Store push-to-install. | Daily / On system event | **Optional** — Store push-to-install; only if you use Store apps. |

**`\Microsoft\Windows\SharedPC`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Account Cleanup` | Disabled | Shared PC account cleanup. | Manual/on-demand | **Optional** — currently disabled; enable only if you use this feature. Shared PC mode; not used. |

**`\Microsoft\Windows\Speech`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `SpeechModelDownloadTask` | Enabled | Downloads speech-recognition models. | Daily | **Disable** — safe to turn off. Speech model download; not needed. |

**`\Microsoft\Windows\WindowsAI\ClickToDo`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `ModelCachingIdle` | Disabled | Caches Click to Do AI models. | When idle | **Disable** — already disabled; no action needed. AI feature (Recall/Click to Do); not part of the minimal VM. |
| `ModelCachingLimit` | Enabled | Caches Click to Do AI models. | On registration | **Disable** — safe to turn off. AI feature (Recall/Click to Do); not part of the minimal VM. |
| `ModelCachingUpdate` | Enabled | Caches Click to Do AI models. | On system event | **Disable** — safe to turn off. AI feature (Recall/Click to Do); not part of the minimal VM. |

**`\Microsoft\Windows\WindowsAI\Recall`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `InitialConfiguration` | Disabled | Configures Windows Recall AI. | At boot / On registration | **Disable** — already disabled; no action needed. AI feature (Recall/Click to Do); not part of the minimal VM. |
| `PolicyConfiguration` | Enabled | Configures Windows Recall AI. | On system event / On session change | **Disable** — safe to turn off. AI feature (Recall/Click to Do); not part of the minimal VM. |

**`\Microsoft\Windows\WindowsAI\Settings`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `InitialConfiguration` | Enabled | Initializes AI settings. | On registration / At boot | **Disable** — safe to turn off. AI feature (Recall/Click to Do); not part of the minimal VM. |

### Devices, drivers & hardware

**`\Microsoft\Windows\Bluetooth`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `UninstallDeviceTask` | Enabled | Removes a Bluetooth device. | Manual/on-demand | **Optional** — Only if you use Bluetooth in the VM. |

**`\Microsoft\Windows\Device Setup`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Driver Recovery on Reboot` | Disabled | Recovers a driver installation after reboot. | At boot | **Keep** — Currently disabled by Windows; leave the default. |
| `Metadata Refresh` | Enabled | Refreshes device metadata from Windows Update. | Manual/on-demand | **Keep** — Driver/device function; leave enabled. |

**`\Microsoft\Windows\DirectX`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `DirectXDatabaseUpdater` | Enabled | Updates the DirectX shader/adapter database. | On system event | **Optional** — DirectX database/cache maintenance; low value. |
| `DXGIAdapterCache` | Enabled | Refreshes the DXGI adapter cache. | At boot / On system event | **Optional** — DirectX database/cache maintenance; low value. |

**`\Microsoft\Windows\Hotpatch`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Monitoring` | Enabled | Monitors hotpatch state. | At boot / At logon / Daily | **Optional** — Only relevant for hotpatch-enabled updates. |

**`\Microsoft\Windows\Kernel`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `La57Cleanup` | Enabled | Kernel LA57 (5-level paging) cleanup task. | Manual/on-demand | **Optional** — Kernel paging cleanup; low value. |

**`\Microsoft\Windows\MemoryDiagnostic`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `AutomaticOfflineMemoryDiagnostic` | Enabled | Schedules an offline memory diagnostic. | At logon | **Optional** — Memory diagnostics; useful only when troubleshooting hardware. |
| `ProcessMemoryDiagnosticEvents` | Enabled | Processes memory-diagnostic events. | On event | **Optional** — Memory diagnostics; useful only when troubleshooting hardware. |
| `RunFullMemoryDiagnostic` | Disabled | Runs a full memory diagnostic. | Manual/on-demand | **Optional** — currently disabled; enable only if you use this feature. Memory diagnostics; useful only when troubleshooting hardware. |

**`\Microsoft\Windows\Multimedia`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `SystemSoundsService` | Enabled | Runs the system sounds service. | At logon | **Optional** — Keep if you need system sounds; otherwise optional. |

**`\Microsoft\Windows\PCRPF`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `PCR Prediction Framework Firmware Update Task` | Enabled | Firmware update task for the PCR prediction framework. | On system event | **Optional** — Firmware update prediction; this VM has no firmware updates. |

**`\Microsoft\Windows\Plug and Play`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Device Install Group Policy` | Enabled | Applies device-installation group policy. | On system event | **Keep** — Driver/device function; leave enabled. |
| `Device Install Reboot Required` | Enabled | Finishes device installation after a required reboot. | On system event / At logon | **Keep** — Driver/device function; leave enabled. |
| `Sysprep Generalize Drivers` | Enabled | Generalizes drivers during Sysprep. | Manual/on-demand | **Keep** — Driver/device function; leave enabled. |

**`\Microsoft\Windows\Printing`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `EduPrintProv` | Enabled | Provisions education printing. | On system event | **Optional** — Only if you print from the VM. |
| `PrinterCleanupTask` | Enabled | Cleans up unused printers. | Every 30 days | **Optional** — Only if you print from the VM. |
| `PrintJobCleanupTask` | Disabled | Cleans up old print jobs. | Weekly | **Optional** — currently disabled; enable only if you use this feature. Only if you print from the VM. |

**`\Microsoft\Windows\USB`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Usb-Notifications` | Enabled | Handles USB device notifications. | On system event | **Optional** — Only if you need USB device notifications. |

**`\Microsoft\Windows\WindowsColorSystem`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Calibration Loader` | Enabled | Loads display color calibration. | At logon / On session change | **Optional** — Only if you calibrate the display. |

### Networking & sync

**`\Microsoft\Windows\Network Connectivity Status Indicator`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `NcsiIdentifyUserProxies` | Enabled | Detects user proxy configuration. | At logon / On session change | **Optional** — Proxy detection helper; not needed. |

**`\Microsoft\Windows\NlaSvc`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `WiFiTask` | Enabled | Network Location Awareness Wi-Fi task. | On system event | **Optional** — Wi-Fi/NLA helper; the VM uses Ethernet. |

**`\Microsoft\Windows\Offline Files`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Background Synchronization` | Disabled | Synchronizes offline files in the background. | Every 2 hours | **Optional** — currently disabled; enable only if you use this feature. Only if you use Offline Files. |
| `Logon Synchronization` | Disabled | Synchronizes offline files at logon. | At logon | **Optional** — currently disabled; enable only if you use this feature. Only if you use Offline Files. |

**`\Microsoft\Windows\Ras`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `MobilityManager` | Enabled | Manages mobility/network connections. | On event | **Optional** — Mobility/network helper; the VM uses virtio Ethernet. |

**`\Microsoft\Windows\UPnP`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `UPnPHostConfig` | Enabled | Configures UPnP host. | Manual/on-demand | **Optional** — Hardware/feature-specific maintenance; keep only if you use that feature. |

**`\Microsoft\Windows\WCM`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `WiFiTask` | Enabled | Runs Wi-Fi connectivity maintenance. | On system event | **Optional** — Wi-Fi connectivity maintenance; the VM uses Ethernet. |

**`\Microsoft\Windows\Windows Filtering Platform`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `BfeOnServiceStartTypeChange` | Enabled | Adjusts the Base Filtering Engine when its start type changes. | On event | **Keep** — Network function; leave enabled. |

**`\Microsoft\Windows\Wininet`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `CacheTask` | Enabled | Maintains the WinINET cache. | At logon | **Optional** — Hardware/feature-specific maintenance; keep only if you use that feature. |

**`\Microsoft\Windows\WlanSvc`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `CDSSync` | Enabled | Syncs WLAN configuration data. | On system event | **Optional** — The VM uses virtio Ethernet, not Wi-Fi. |
| `MoProfileManagement` | Enabled | Manages mobile-broadband profiles. | On system event | **Optional** — The VM uses virtio Ethernet, not Wi-Fi. |

**`\Microsoft\Windows\Work Folders`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Work Folders Logon Synchronization` | Enabled | Synchronizes Work Folders at logon. | At logon | **Optional** — Only if you use Work Folders. |
| `Work Folders Maintenance Work` | Enabled | Runs Work Folders maintenance. | At logon | **Optional** — Only if you use Work Folders. |

**`\Microsoft\Windows\Workplace Join`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Automatic-Device-Join` | Disabled | Automatically joins the device to a workplace. | At logon / On event | **Optional** — currently disabled; enable only if you use this feature. Only for workplace join/Azure AD; not used. |
| `Device-Sync` | Disabled | Syncs workplace-join device state. | On system event | **Optional** — currently disabled; enable only if you use this feature. Only for workplace join/Azure AD; not used. |
| `Recovery-Check` | Disabled | Checks workplace-join recovery state. | At logon / On session change | **Optional** — currently disabled; enable only if you use this feature. Only for workplace join/Azure AD; not used. |

**`\Microsoft\Windows\WwanSvc`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `NotificationTask` | Enabled | Handles mobile-broadband notifications. | On system event | **Optional** — Mobile broadband; not present in this VM. |
| `OobeDiscovery` | Enabled | Discovers mobile-broadband hardware during OOBE. | On system event | **Optional** — Mobile broadband; not present in this VM. |

### Shell, input & management

**`\Microsoft\Windows\FileHistory`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `File History (maintenance mode)` | Enabled | Runs File History backup maintenance. | Manual/on-demand | **Optional** — Only if you use File History. |

**`\Microsoft\Windows\Input`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `InputSettingsRestoreDataAvailable` | Enabled | Syncs/restores input-device settings. | On system event | **Optional** — Input-device sync; only if you use touch/pen. |
| `LocalUserSyncDataAvailable` | Enabled | Syncs/restores input-device settings. | On system event | **Optional** — Input-device sync; only if you use touch/pen. |
| `MouseSyncDataAvailable` | Enabled | Syncs/restores input-device settings. | On system event | **Optional** — Input-device sync; only if you use touch/pen. |
| `PenSyncDataAvailable` | Enabled | Syncs/restores input-device settings. | On system event | **Optional** — Input-device sync; only if you use touch/pen. |
| `RemoteMouseSyncDataAvailable` | Enabled | Syncs/restores input-device settings. | On system event | **Optional** — Input-device sync; only if you use touch/pen. |
| `RemotePenSyncDataAvailable` | Enabled | Syncs/restores input-device settings. | On system event | **Optional** — Input-device sync; only if you use touch/pen. |
| `RemoteTouchpadSyncDataAvailable` | Enabled | Syncs/restores input-device settings. | On system event | **Optional** — Input-device sync; only if you use touch/pen. |
| `TouchpadSyncDataAvailable` | Enabled | Syncs/restores input-device settings. | On system event | **Optional** — Input-device sync; only if you use touch/pen. |

**`\microsoft\windows\input`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `syncpensettings` | Enabled | Syncs pen settings. | On system event | **Optional** — Input-device sync; only if you use touch/pen. |

**`\Microsoft\Windows\Location`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `WindowsActionDialog` | Enabled | Shows the Windows location action dialog. | On system event | **Optional** — Location action dialog; not needed on a headless/RDP VM. |

**`\Microsoft\Windows\Management\Autopilot`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `DetectHardwareChange` | Disabled | Autopilot/MDM provisioning task. | On system event | **Optional** — currently disabled; enable only if you use this feature. Autopilot/MDM provisioning; not used. |
| `RemediateHardwareChange` | Disabled | Autopilot/MDM provisioning task. | At boot | **Optional** — currently disabled; enable only if you use this feature. Autopilot/MDM provisioning; not used. |

**`\Microsoft\Windows\Management\Provisioning`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Cellular` | Enabled | Autopilot/MDM provisioning task. | On system event | **Optional** — Autopilot/MDM provisioning; not used. |
| `Logon` | Enabled | Autopilot/MDM provisioning task. | At logon | **Optional** — Autopilot/MDM provisioning; not used. |
| `MdmDiagnosticsCleanup` | Disabled | Autopilot/MDM provisioning task. | At boot | **Optional** — currently disabled; enable only if you use this feature. Autopilot/MDM provisioning; not used. |
| `Retry` | Disabled | Autopilot/MDM provisioning task. | At boot | **Optional** — currently disabled; enable only if you use this feature. Autopilot/MDM provisioning; not used. |
| `RunOnReboot` | Disabled | Autopilot/MDM provisioning task. | At boot | **Optional** — currently disabled; enable only if you use this feature. Autopilot/MDM provisioning; not used. |

**`\Microsoft\Windows\RemoteAssistance`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `RemoteAssistanceTask` | Enabled | Runs Remote Assistance. | On event / On registration | **Optional** — Only if you use Remote Assistance. |

**`\Microsoft\Windows\Shell`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `CreateObjectTask` | Enabled | Creates shell objects for new users. | Manual/on-demand | **Optional** — Shell object creation; low value. |
| `FamilySafetyMonitor` | Enabled | Family Safety monitoring/refresh. | Manual/on-demand | **Optional** — Only if you use Family Safety. |
| `FamilySafetyRefreshTask` | Enabled | Family Safety monitoring/refresh. | On system event | **Optional** — Only if you use Family Safety. |
| `IndexerAutomaticMaintenance` | Enabled | Maintains the Windows Search index. | Manual/on-demand | **Optional** — Keep if Windows Search is enabled; optional if WSearch is off. |
| `ThemeAssetTask_SyncFODState` | Disabled | Syncs theme assets/images. | When idle | **Optional** — currently disabled; enable only if you use this feature. Only if you use synced themes. |
| `ThemesSyncedImageDownload` | Enabled | Syncs theme assets/images. | Manual/on-demand | **Optional** — Only if you use synced themes. |
| `UpdateUserPictureTask` | Enabled | Updates the user account picture. | On system event | **Optional** — Only if you change account pictures. |
| `UpdateUserPictureTaskContained` | Enabled | Updates the user account picture. | On system event | **Optional** — Only if you change account pictures. |

**`\Microsoft\Windows\Task Manager`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Interactive` | Enabled | Task Manager integration task. | Manual/on-demand | **Optional** — Task Manager integration; low value. |

**`\Microsoft\Windows\TextServicesFramework`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `MsCtfMonitor` | Enabled | Monitors the text services framework (IME/input). | At logon | **Keep** — Shell/input feature; leave enabled. |

**`\Microsoft\Windows\User Profile Service`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `HiveUploadTask` | Disabled | Uploads user-profile hive data for enterprise roaming. | Every 12 hours | **Optional** — currently disabled; enable only if you use this feature. Enterprise profile roaming; not used. |

**`\Microsoft\Windows\Windows Media Sharing`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `UpdateLibrary` | Enabled | Updates the media-sharing library. | On event | **Optional** — Only if you use Windows Media Sharing. |

### Telemetry, feedback & diagnostics

**`\Microsoft\Windows\AccountHealth`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `RecoverabilityToastTask` | Enabled | Shows an account recovery/health notification. | On session change | **Disable** — safe to turn off. Account-health/recovery toast; not needed. |

**`\Microsoft\Windows\Application Experience`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `MareBackup` | Disabled | Backs up application-experience data. | Manual/on-demand | **Disable** — already disabled; no action needed. Compatibility/telemetry tasks; not needed. |
| `Microsoft Compatibility Appraiser Exp` | Disabled | Compatibility appraiser data collection. | On system event | **Disable** — already disabled; no action needed. Compatibility/telemetry tasks; not needed. |
| `PcaPatchDbTask` | Enabled | Updates compatibility database | Every 12 hours | **Disable** — safe to turn off. Compatibility/telemetry tasks; not needed. |
| `SdbinstMergeDbTask` | Enabled | Merges application-compatibility databases. | On system event | **Disable** — safe to turn off. Compatibility/telemetry tasks; not needed. |
| `StartupAppTask` | Disabled | Scans startup apps for compatibility/telemetry. | Manual/on-demand | **Disable** — already disabled; no action needed. Compatibility/telemetry tasks; not needed. |

**`\Microsoft\Windows\Autochk`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Proxy` | Disabled | Runs the autochk proxy task. | At boot | **Disable** — already disabled; no action needed. Autochk proxy; not needed. |

**`\Microsoft\Windows\CloudExperienceHost`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `CreateObjectTask` | Disabled | Creates Cloud Experience Host objects during setup/first run. | Manual/on-demand | **Disable** — already disabled; no action needed. Cloud content host; not needed. |

**`\Microsoft\Windows\ConsentUX\UnifiedConsent`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `UnifiedConsentSyncTask` | Enabled | Syncs privacy-consent settings. | On system event / Daily | **Disable** — safe to turn off. Privacy-consent sync; not needed. |

**`\Microsoft\Windows\Customer Experience Improvement Program`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Consolidator` | Disabled | Uploads Customer Experience Improvement Program data. | Every 6 hours | **Disable** — already disabled; no action needed. CEIP telemetry; not needed. |
| `UsbCeip` | Disabled | Collects USB usage telemetry for CEIP. | Manual/on-demand | **Disable** — already disabled; no action needed. CEIP telemetry; not needed. |

**`\Microsoft\Windows\Diagnosis`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `RecommendedTroubleshootingScanner` | Enabled | Scans for recommended troubleshooting scenarios. | On system event | **Disable** — safe to turn off. Diagnostic scenarios; not needed. |
| `Scheduled` | Enabled | Runs scheduled diagnostic scenarios. | Manual/on-demand | **Disable** — safe to turn off. Diagnostic scenarios; not needed. |
| `UnexpectedCodepath` | Enabled | Handles unexpected diagnostic code paths. | On system event | **Disable** — safe to turn off. Diagnostic scenarios; not needed. |

**`\Microsoft\Windows\DiskDiagnostic`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `Microsoft-Windows-DiskDiagnosticDataCollector` | Disabled | Collects disk diagnostic telemetry. | Manual/on-demand | **Disable** — already disabled; no action needed. Disk diagnostic telemetry; not needed. |
| `Microsoft-Windows-DiskDiagnosticResolver` | Disabled | Resolves disk diagnostic incidents. | At logon | **Disable** — already disabled; no action needed. Disk diagnostic telemetry; not needed. |

**`\Microsoft\Windows\DUSM`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `dusmtask` | Enabled | Data usage/service-management maintenance. | On system event | **Optional** — Data usage/service-management maintenance; low value. |

**`\Microsoft\Windows\Feedback\Siuf`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `DmClient` | Disabled | Runs the feedback/telemetry client. | Manual/on-demand | **Disable** — already disabled; no action needed. Feedback/telemetry; not needed. |
| `DmClientOnScenarioDownload` | Disabled | Handles feedback scenario downloads. | On system event | **Disable** — already disabled; no action needed. Feedback/telemetry; not needed. |

**`\Microsoft\Windows\Flighting\FeatureConfig`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `BootstrapUsageDataReporting` | Enabled | Windows feature-configuration/experimentation task. | Every 15 min | **Disable** — safe to turn off. Feature experimentation/usage reporting; not needed. |
| `GovernedFeatureUsageProcessing` | Enabled | Windows feature-configuration/experimentation task. | On system event | **Disable** — safe to turn off. Feature experimentation/usage reporting; not needed. |
| `ReconcileConfigs` | Enabled | Windows feature-configuration/experimentation task. | On system event | **Disable** — safe to turn off. Feature experimentation/usage reporting; not needed. |
| `ReconcileFeatures` | Enabled | Windows feature-configuration/experimentation task. | On system event | **Disable** — safe to turn off. Feature experimentation/usage reporting; not needed. |
| `SafeguardsReconciliation` | Enabled | Windows feature-configuration/experimentation task. | On system event | **Disable** — safe to turn off. Feature experimentation/usage reporting; not needed. |
| `UsageDataFlushing` | Enabled | Windows feature-configuration/experimentation task. | On system event | **Disable** — safe to turn off. Feature experimentation/usage reporting; not needed. |
| `UsageDataReceiver` | Enabled | Windows feature-configuration/experimentation task. | On system event | **Disable** — safe to turn off. Feature experimentation/usage reporting; not needed. |
| `UsageDataReporting` | Enabled | Windows feature-configuration/experimentation task. | On system event | **Disable** — safe to turn off. Feature experimentation/usage reporting; not needed. |

**`\Microsoft\Windows\Flighting\OneSettings`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `RefreshCache` | Enabled | Refreshes the OneSettings configuration cache. | Every 283 min / On system event | **Disable** — safe to turn off. Feature experimentation/usage reporting; not needed. |

**`\Microsoft\Windows\Maintenance`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `WinSAT` | Disabled | Runs the Windows Experience Index / WinSAT assessment. | Manual/on-demand | **Disable** — already disabled; no action needed. WinSAT performance assessment; not needed. |

**`\Microsoft\Windows\Maps`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `MapsToastTask` | Disabled | Shows Maps-related toast notifications. | Manual/on-demand | **Disable** — already disabled; no action needed. Maps updates/toasts; not needed. |
| `MapsUpdateTask` | Disabled | Updates offline Maps data. | Daily | **Disable** — already disabled; no action needed. Maps updates/toasts; not needed. |

**`\Microsoft\Windows\PerformanceTrace`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `ShowFeedbackToast` | Enabled | Shows a performance feedback toast. | On system event | **Disable** — safe to turn off. Performance/WHEA feedback toasts; not needed. |
| `WhesvcToast` | Enabled | Shows a Windows Hardware Error Service toast. | On system event | **Disable** — safe to turn off. Performance/WHEA feedback toasts; not needed. |

**`\Microsoft\Windows\Power Efficiency Diagnostics`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `AnalyzeSystem` | Disabled | Collects power-efficiency diagnostic data. | Manual/on-demand | **Disable** — already disabled; no action needed. Power diagnostic telemetry; not needed. |

**`\Microsoft\Windows\RetailDemo`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `CleanupOfflineContent` | Disabled | Cleans up retail-demo content. | Daily | **Disable** — already disabled; no action needed. Retail demo content; not needed. |

**`\Microsoft\Windows\Sustainability`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `PowerGridForecastTask` | Enabled | Fetches power-grid forecast data. | On system event / Daily | **Disable** — safe to turn off. Sustainability telemetry; not needed. |
| `SustainabilityTelemetry` | Enabled | Collects sustainability telemetry. | Manual/on-demand | **Disable** — safe to turn off. Sustainability telemetry; not needed. |

**`\Microsoft\Windows\UsageAndQualityInsights`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `UsageAndQualityInsights-MaintenanceTask` | Enabled | Maintains usage/quality telemetry. | Daily | **Disable** — safe to turn off. Usage/quality telemetry; not needed. |

**`\Microsoft\Windows\WDI`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `ResolutionHost` | Enabled | Hosts diagnostic resolution workflows. | Manual/on-demand | **Optional** — Diagnostic resolution host; only needed while troubleshooting. |

**`\Microsoft\Windows\Windows Error Reporting`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `QueueReporting` | Disabled | Queues and uploads Windows Error Reporting crash data. | At boot / On system event / Every 4 hours | **Disable** — already disabled; no action needed. Error-report upload; not needed. |

### Optional consumer & third-party

**`\Microsoft\XblGameSave`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `XblGameSaveTask` | Enabled | XblGameSave Standby Task | No active trigger | **Optional** — Only if you game in the VM. |

**`\SoftLanding\S-1-5-21-2627163621-65005677-2634483723-1001`**

| Task | State | What it does | Trigger | Recommendation |
| --- | --- | --- | --- | --- |
| `SoftLandingCreativeManagementTask` | Enabled | Manages Windows tips/Spotlight content. | On system event / Once / Daily | **Disable** — safe to turn off. Windows tips/Spotlight content; consumer feature, not needed. |

## Defender `.bak` definitions

These four task definitions are present only as `.bak` files. The Task Scheduler registry still has entries for the non-`.bak` names, but there is no readable XML definition. If Defender is intentionally disabled, leave them alone. If you are re-enabling Defender, repair the task definitions (or let Windows rebuild them) before relying on scheduled scans.

| Task | State | What it does | Recommendation |
| --- | --- | --- | --- |
| `Windows Defender Cache Maintenance` | Backup (.bak) | Maintains the Defender scan cache. | **Backup** — leave disabled unless repairing Defender. |
| `Windows Defender Cleanup` | Backup (.bak) | Cleans up Defender scan artifacts. | **Backup** — leave disabled unless repairing Defender. |
| `Windows Defender Scheduled Scan` | Backup (.bak) | Runs the scheduled Defender scan. | **Backup** — leave disabled unless repairing Defender. |
| `Windows Defender Verification` | Backup (.bak) | Verifies Defender platform health. | **Backup** — leave disabled unless repairing Defender. |

## Registry-only task paths

These paths are registered in `TaskCache\Tree` but have no XML definition in the offline export. They are usually built-in or dynamically registered tasks. Treat their state as **Unknown** and verify them live with `Get-ScheduledTask` before changing anything.

| Task path | Category | What it likely does | Recommendation |
| --- | --- | --- | --- |
| `\Microsoft\OneCore\DirectX\DirectXDatabaseUpdater` | Devices, drivers & hardware | Updates the DirectX database. | **Optional** — Updates the DirectX database. |
| `\Microsoft\Windows\Application Experience\AitAgent` | Telemetry, feedback & diagnostics | Application Impact Telemetry agent. | **Disable** — Compatibility/telemetry tasks; not needed. |
| `\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser` | Telemetry, feedback & diagnostics | Compatibility appraiser data collection. | **Disable** — Compatibility/telemetry tasks; not needed. |
| `\Microsoft\Windows\Application Experience\ProgramDataUpdater` | Telemetry, feedback & diagnostics | Uploads application compatibility data. | **Disable** — Compatibility/telemetry tasks; not needed. |
| `\Microsoft\Windows\Clip\ClipESU` | Time, language & licensing | Clip/ESU subscription licensing task. | **Keep** — Clip licensing; leave enabled. |
| `\Microsoft\Windows\Clip\ClipESUConsumer` | Time, language & licensing | Clip/ESU subscription licensing task. | **Keep** — Clip licensing; leave enabled. |
| `\Microsoft\Windows\Clip\ClipEsuConsumerProcessPreOrder` | Time, language & licensing | Clip/ESU subscription licensing task. | **Keep** — Clip licensing; leave enabled. |
| `\Microsoft\Windows\Clip\ClipEsuConsumerProcessRefund` | Time, language & licensing | Clip/ESU subscription licensing task. | **Keep** — Clip licensing; leave enabled. |
| `\Microsoft\Windows\Clip\EnableClipESU` | Time, language & licensing | Clip/ESU subscription licensing task. | **Keep** — Clip licensing; leave enabled. |
| `\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask` | Telemetry, feedback & diagnostics | Kernel Customer Experience Improvement Program telemetry. | **Disable** — CEIP telemetry; not needed. |
| `\Microsoft\Windows\Live\Roaming\MaintenanceTask` | Apps, Store & AI | Microsoft account roaming sync. | **Optional** — Microsoft account roaming sync. |
| `\Microsoft\Windows\Live\Roaming\SynchronizeWithStorage` | Apps, Store & AI | Microsoft account roaming sync. | **Optional** — Microsoft account roaming sync. |
| `\Microsoft\Windows\MemoryDiagnostic\CorruptionDetector` | Devices, drivers & hardware | Memory diagnostic helper. | **Optional** — Memory diagnostics; useful only when troubleshooting hardware. |
| `\Microsoft\Windows\MemoryDiagnostic\DecompressionFailureDetector` | Devices, drivers & hardware | Memory diagnostic helper. | **Optional** — Memory diagnostics; useful only when troubleshooting hardware. |
| `\Microsoft\Windows\MemoryDiagnostic\MemUsageTask` | Devices, drivers & hardware | Memory diagnostic helper. | **Optional** — Memory diagnostics; useful only when troubleshooting hardware. |
| `\Microsoft\Windows\NetTrace\GatherNetworkInfo` | Telemetry, feedback & diagnostics | Collects network diagnostic traces. | **Optional** — Collects network diagnostic traces. |
| `\Microsoft\Windows\PLA\System\ConvertLogEntries` | Telemetry, feedback & diagnostics | Converts performance log entries. | **Optional** — Converts performance log entries. |
| `\Microsoft\Windows\SettingSync\BackgroundUploadTask` | Apps, Store & AI | Syncs/backs up Windows settings. | **Optional** — Syncs/backs up Windows settings. |
| `\Microsoft\Windows\SettingSync\BackupTask` | Apps, Store & AI | Syncs/backs up Windows settings. | **Optional** — Syncs/backs up Windows settings. |
| `\Microsoft\Windows\SettingSync\NetworkStateChangeTask` | Apps, Store & AI | Syncs/backs up Windows settings. | **Optional** — Syncs/backs up Windows settings. |
| `\Microsoft\Windows\Shell\CrawlStartPages` | Shell, input & management | Indexes Start-page content for Windows Search. | **Optional** — Indexes Start-page content for Windows Search. |
| `\Microsoft\Windows\TaskScheduler\Idle Maintenance` | Windows Update & servicing | Task Scheduler maintenance. | **Keep** — Task Scheduler maintenance. |
| `\Microsoft\Windows\TaskScheduler\Maintenance Configurator` | Windows Update & servicing | Task Scheduler maintenance. | **Keep** — Task Scheduler maintenance. |
| `\Microsoft\Windows\TaskScheduler\Manual Maintenance` | Windows Update & servicing | Task Scheduler maintenance. | **Keep** — Task Scheduler maintenance. |
| `\Microsoft\Windows\TaskScheduler\Regular Maintenance` | Windows Update & servicing | Task Scheduler maintenance. | **Keep** — Task Scheduler maintenance. |
| `\Microsoft\Windows\UpdateOrchestrator\UpdateModelTask` | Windows Update & servicing | Updates the Update Orchestrator model. | **Keep** — Windows Update orchestration; leave enabled. |
| `\Microsoft\Windows\Windows Activation Technologies\ValidationTask` | Time, language & licensing | Validates Windows activation. | **Keep** — Validates Windows activation. |
| `\Microsoft\Windows\Windows Activation Technologies\ValidationTaskDeadline` | Time, language & licensing | Validates Windows activation. | **Keep** — Validates Windows activation. |
| `\Microsoft\Windows\Windows Subsystem For Linux\AptPackageIndexUpdate` | Apps, Store & AI | Updates the WSL APT package index. | **Optional** — Updates the WSL APT package index. |
| `\Microsoft\Windows\WindowsBackup\ConfigNotification` | Storage health & maintenance | Notifies about Windows Backup configuration. | **Optional** — Notifies about Windows Backup configuration. |
| `\Microsoft\Windows\WindowsUpdate\Automatic App Update` | Windows Update & servicing | Automatic app update task. | **Keep** — Windows Update; leave enabled. |
| `\Microsoft\Windows\WindowsUpdate\sihboot` | Windows Update & servicing | Servicing/setup boot task. | **Keep** — Windows Update; leave enabled. |
| `\Microsoft\Windows\WS\Badge Update` | Apps, Store & AI | Updates Store app badges. | **Optional** — Windows Store licensing/badge maintenance; only if you use Store apps. |
| `\Microsoft\Windows\WS\License Validation` | Apps, Store & AI | Validates Store licenses. | **Optional** — Windows Store licensing/badge maintenance; only if you use Store apps. |
| `\Microsoft\Windows\WS\Sync Licenses` | Apps, Store & AI | Syncs Store licenses. | **Optional** — Windows Store licensing/badge maintenance; only if you use Store apps. |
| `\Microsoft\Windows\WS\WSRefreshBannedAppsListTask` | Apps, Store & AI | Refreshes the Store banned-apps list. | **Optional** — Windows Store licensing/badge maintenance; only if you use Store apps. |
| `\Microsoft\Windows\WS\WSTask` | Apps, Store & AI | Windows Store maintenance task. | **Optional** — Windows Store licensing/badge maintenance; only if you use Store apps. |

## What to disable first

The following are the highest-value additions beyond the existing `disable-scheduled-tasks.ps1`. They are all in the **Disable** group above; the detailed table gives the exact path and state.

- **`\Microsoft\Windows\AccountHealth`** — `RecoverabilityToastTask`
- **`\Microsoft\Windows\ConsentUX\UnifiedConsent`** — `UnifiedConsentSyncTask`
- **`\Microsoft\Windows\Diagnosis`** — `RecommendedTroubleshootingScanner`, `Scheduled`, `UnexpectedCodepath`
- **`\Microsoft\Windows\Flighting\FeatureConfig`** — `BootstrapUsageDataReporting`, `GovernedFeatureUsageProcessing`, `ReconcileConfigs`, `ReconcileFeatures`, `SafeguardsReconciliation`, `UsageDataFlushing`, `UsageDataReceiver`, `UsageDataReporting`
- **`\Microsoft\Windows\Flighting\OneSettings`** — `RefreshCache`
- **`\Microsoft\Windows\PerformanceTrace`** — `ShowFeedbackToast`, `WhesvcToast`
- **`\Microsoft\Windows\Speech`** — `SpeechModelDownloadTask`
- **`\Microsoft\Windows\Sustainability`** — `PowerGridForecastTask`, `SustainabilityTelemetry`
- **`\Microsoft\Windows\UsageAndQualityInsights`** — `UsageAndQualityInsights-MaintenanceTask`
- **`\Microsoft\Windows\WindowsAI\ClickToDo`** — `ModelCachingIdle`, `ModelCachingLimit`, `ModelCachingUpdate`
- **`\Microsoft\Windows\WindowsAI\Recall`** — `InitialConfiguration`, `PolicyConfiguration`
- **`\Microsoft\Windows\WindowsAI\Settings`** — `InitialConfiguration`
- **`\SoftLanding\S-1-5-21-2627163621-65005677-2634483723-1001`** — `SoftLandingCreativeManagementTask`

Already covered by the existing script: `Application Experience`, `Customer Experience Improvement Program`, `Feedback`, `Autochk`, `CloudExperienceHost`, `DiskDiagnostic`, `PI` (SQM), `RetailDemo`, `Maps`, `Windows Error Reporting`, `Maintenance` (WinSAT), and `Power Efficiency Diagnostics`.

**Script caveat:** the current `disable-scheduled-tasks.ps1` disables the whole `\Microsoft\Windows\PI\` folder. That folder also contains `Secure-Boot-Update`, which this analysis marks **Keep**. Secure Boot is off on this VM, so the practical impact is small, but narrowing the script to `Sqm-Tasks` is safer if you want to preserve the Secure Boot update policy.

## What not to touch

- **Windows Update and servicing**: `WindowsUpdate`, `UpdateOrchestrator`, `InstallService`, `WaaSMedic`, `Servicing`, `Setup`.
- **Defender**, if you keep it enabled. If you intentionally disabled it, the `.bak` entries can stay as they are.
- **Time and licensing**: time synchronization, time zone, Software Protection, Clip/subscription licensing.
- **Storage health**: Chkdsk, Data Integrity Scan, Defrag, Disk Cleanup, Storage Sense, System Restore, Registry idle backup.
- **Security/identity**: TPM, certificate services, Secure Boot update, firewall/BFE.
- **Recovery**: WinRE verification.
- **Registry-only core tasks**: `Automatic App Update`, `ClipESU`, `ClipESUConsumer`, `ClipEsuConsumerProcessPreOrder`, `ClipEsuConsumerProcessRefund`, `EnableClipESU`, `Idle Maintenance`, `Maintenance Configurator`, `Manual Maintenance`, `Regular Maintenance`, `sihboot`, `UpdateModelTask`, `ValidationTask`, `ValidationTaskDeadline`.

## Applying changes safely

Run these in an elevated PowerShell session inside the guest. Start by reading the live state, because the offline XML cannot show policy overrides or protected-task behavior:

```powershell
Get-ScheduledTask | Sort-Object TaskPath, TaskName |
  Select-Object State, TaskPath, TaskName | Format-Table -AutoSize
```

Disable one folder at a time and keep the output:

```powershell
$path = '\Microsoft\Windows\Diagnosis\'
Get-ScheduledTask -TaskPath $path |
  ForEach-Object { Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath }
```

Re-enable with the matching `Enable-ScheduledTask` call. Do not delete task XML files: a feature update or Windows repair may need them, and deletion is harder to undo than disabling.

Notes:

- Some tasks are protected; `Disable-ScheduledTask` can fail with access denied. That is expected.
- Windows Update or a feature update can re-enable tasks. Re-check after major updates.
- The four Defender `.bak` tasks are a special case: do not rename them back blindly while Defender is disabled.
- The registry-only paths should be checked live; some may be stale entries from an earlier build.

## Appendix: method and limits

- **Source**: offline copy of `C:\Windows\System32\Tasks` plus the `TaskCache` registry export from `win11-stock.raw`.
- **Normal active definitions**: task XML exists with a non-`.bak` filename and a matching `TaskCache\Tree` entry.
- **State**: `Disabled` only when the XML explicitly contains `<Enabled>false</Enabled>`. Absence of the element means enabled, which is the Windows default.
- **Triggers**: summarized from the XML. “On system event” covers `WnfStateChangeTrigger`; these are event-driven and not a fixed schedule.
- **Descriptions**: resource strings such as `$(@%systemroot%\...)` were replaced with a human summary inferred from the task name, folder, and action. They are descriptive, not Microsoft’s official text.
- **Not executed**: no task was run, and no live service state was queried. Use `Get-ScheduledTask` for the final word before disabling anything.

Related: [`docs/windows-vm.md`](windows-vm.md), [`scripts/windows/disable-scheduled-tasks.ps1`](../scripts/windows/disable-scheduled-tasks.ps1).
