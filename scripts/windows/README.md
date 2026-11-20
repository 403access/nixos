# Windows guest helper scripts

Run these inside the Windows 11 guest from a helper CD. They are all
double-click launchers that self-elevate through UAC and call PowerShell with
`-ExecutionPolicy Bypass`, so a machine policy that blocks scripts does not
matter.

| File | Purpose |
| --- | --- |
| `enable-rdp.bat` | Starts `TermService`, enables RDP, recreates the TCP 3389 rule, sets the network profile to Private |
| `restore-point.bat` | Enables System Restore and creates the `Before debloat` checkpoint |
| `debloat.bat` | Runs `windows/scripts/SetupComplete.ps1 -ProfileName lean` |
| `tune.bat` | Enables TRIM, sets High Performance, disables hibernation/Fast Startup |

## Build and insert the CD

```bash
./make-helper-iso.sh /tmp/windows-helper.iso

sudo virsh change-media win11-stock sdb --eject --live
sudo virsh change-media win11-stock sdb /tmp/windows-helper.iso --insert --live
```

The virtio-win CD can be replaced once the guest tools are installed.

Use a **new output filename** each time: an ISO that is inserted in a running
domain is open, and `xorriso` cannot overwrite it. `enable-rdp.bat` and the
others need CRLF line endings; the repository enforces that through
`.gitattributes`.

In Windows: File Explorer → the CD → F5 → double-click the launcher → **Ja**
on UAC.
