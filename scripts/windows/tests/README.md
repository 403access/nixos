# Tests for the Windows slim helpers

These tests cover the Search/Defender helpers, the profile presets, the service
lists and the offline hive patch.  They run without a Windows VM.

## Quick start

From the repository root:

```bash
./scripts/windows/tests/run-tests.sh
```

The runner executes:

1. `offline-registry.Tests.sh` — shell tests for the offline hive library and
   `apply.sh --hive-dir`.
2. Pester tests via `run-tests.ps1` when `pwsh` is installed.
3. `offline-hive-smoke.sh` only when `OFFLINE_TEST_HIVE_DIR` points at real
   hives.

On Windows PowerShell:

```powershell
.\scripts\windows\tests\run-tests.ps1
```

`run-tests.ps1` installs Pester into the current user scope if it is missing.

## What is covered

| File | Checks |
| --- | --- |
| `Search.Tests.ps1` | `WSearch` is disabled, taskbar search is hidden, processes are stopped, and the saved state restores the previous mode. |
| `Defender.Tests.ps1` | Tamper Protection refusal, policy keys, `WinDefend`/`WdNisSvc` start types, enable/disable, and the non-admin guards. |
| `Profiles.Tests.ps1` | Developer enables Search, SysMain and SSH; Power/Regular keep Search and use the balanced/light lists. |
| `Services.Tests.ps1` | `-IncludeSearch`/`-IncludeSysMain` behavior, protected-service handling, and the stock app/service lists. |
| `Helper.Tests.ps1` | The tabbed UI still has the three tabs and the Search/Defender/profile actions, and plain Developer keeps Defender on. |
| `Verify.Tests.ps1` | The live verifier's check helpers accept the hardened state and reject running services/processes. |
| `Wrapper.Tests.ps1` | Every `.bat` launcher resolves, every `.ps1` parses, and the Search/Defender/verifier launchers exist. |
| `offline-registry.Tests.sh` | `CurrentControlSet`, service/policy/IFEO merges, binary/task renames, verification failures, idempotency, and `apply.sh` in hive mode. |

The PowerShell tests mock the Windows-only cmdlets.  `TestHelpers.ps1` creates
inert stubs only when the real cmdlet is unavailable, so the same tests run on
macOS, Linux and Windows.

## Offline registry tests

The shell suite uses `fake-hivexregedit.py`, which stores values in a JSON
sidecar.  It exercises the merge/verify logic without libhivex or a disk image.

To test the same code against real hives, copy a known-good `SYSTEM` and
`SOFTWARE` hive into a directory and run:

```bash
OFFLINE_TEST_HIVE_DIR=/path/to/hives \
  ./scripts/windows/tests/offline-hive-smoke.sh
```

The real hives are copied first; the originals are never modified.

## Live verification inside Windows

After a profile or an offline patch, run:

```powershell
.\verify-minimal.bat
```

or:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File verify-minimal.ps1 -Json
```

It checks the Search service and files, Defender processes, active binaries,
policies, IFEO blocks and scheduled tasks.  It changes nothing and exits `1` if
a check fails.

## CI

`.github/workflows/windows-tests.yml` runs the shell suite on Ubuntu and the
Pester suite on both Ubuntu and Windows.  The real-hive smoke test is local
only because it needs a Windows hive; set `OFFLINE_TEST_HIVE_DIR` to include
it in `run-tests.sh`.