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
| `enable-autologon.bat` | Prompts for the account password and enables automatic logon |
| `disable-autologon.bat` | Removes automatic logon and the stored password |
| `trim-memory.bat` | Removes OneDrive startup, disables Widgets/Recall/background apps |
| `trim-memory-aggressive.bat` | Same, plus disables Search indexing and SysMain |
| `tune.bat` | Enables TRIM, sets High Performance, disables hibernation/Fast Startup |

## Build and insert the CD

These files are edited in the Mac checkout but the CD must be built on the
NixOS host, which has `xorriso` and the libvirt tools.  Two machines, two
steps:

On the **Mac**:

```bash
scp -r /Users/olivermolnar/Desktop/nixos/scripts/windows \
  nixos@192.168.178.5:~/Desktop/nixos/scripts/
```

On the **NixOS host**:

```bash
cd ~/Desktop/nixos/scripts/windows
ls                                        # the .bat/.ps1 files must be there
./make-helper-iso.sh /tmp/windows-helper.iso

sudo virsh change-media win11-stock sdb --eject --live
sudo virsh change-media win11-stock sdb /tmp/windows-helper.iso --insert --live
```

`make-helper-iso.sh` also copies `windows/scripts/SetupComplete.ps1` into the
CD, so the debloat action is always available.

`trim-memory.bat` only reduces what Windows itself keeps resident. The host
still holds the full VM allocation; use `scripts/vm-memory.sh` for that.  If `insert` reports
`Cannot access storage file`, the ISO was not built (usually because the host
did not have the scripts yet) — run `ls` in the directory and rebuild.

The virtio-win CD can be replaced once the guest tools are installed.

Use a **new output filename** each time: an ISO that is inserted in a running
domain is open, and `xorriso` cannot overwrite it. `enable-rdp.bat` and the
others need CRLF line endings; the repository enforces that through
`.gitattributes`.

In Windows: File Explorer → the CD → F5 → double-click the launcher → **Ja**
on UAC.
