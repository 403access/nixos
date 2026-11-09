# Plan: Ultra-slim Windows 11 image from NixOS

**Status:** implemented
**Scope:** documentation (English + German), a reproducible NixOS build toolkit, and marketing entry points.

## Goal

Make it possible to build a lean, unattended Windows 11 installation ISO from
this repository, with a documented path for both a conservative debloat and an
experimental "micro" image. The documentation must be honest about what NixOS
can and cannot do natively, and the marketing site must link to the new guide.

## Deliverables

- [x] A repo-level plan (this file).
- [x] A Nix shell with `wimlib`, `p7zip`, `xorriso`, `python3` and supporting tools.
- [x] `windows/build-win11.sh`: extract ISO, select an edition, inject
      `autounattend.xml`, add first-boot provisioning, recapture the WIM,
      optionally solid-compress it, and rebuild a bootable ISO.
- [x] A safe `autounattend.xml` renderer: local account, no Microsoft account,
      optional hardware-check bypass, generated password by default.
- [x] A first-boot PowerShell script with `safe`, `lean` and `micro` profiles.
- [x] English guide at `website/docs/guides/windows-11-slim-image.md`.
- [x] German guide at
      `website/i18n/de/docusaurus-plugin-content-docs/current/guides/windows-11-slim-image.md`.
- [x] Docusaurus `de` locale, locale switcher, sidebar entry, and navbar item.
- [x] Marketing page `/windows` (bilingual by locale) plus a homepage teaser.
- [x] Root README section linking the guide.
- [x] Verification: shell syntax, Python syntax, XML validation, Docusaurus build.

## Non-goals

- Shipping or downloading Microsoft binaries. The user must provide a legally
  obtained Windows 11 ISO.
- Bypassing Windows licensing or activation.
- Promising that an unsupported, heavily stripped image will remain serviceable.
- Removing Defender, Windows Update, the servicing stack, or WinSxS by default.

## Content strategy

The guide separates three layers that are often mixed together:

1. **Build media**: extract, modify, recompress and repack the ISO on NixOS.
2. **Unattended setup**: skip the Microsoft account and optionally the hardware
   checks, with a secure local account.
3. **First-boot debloat**: remove provisioned AppX packages and apply policy
   tweaks after Windows Setup has run.

This is more reliable than deleting `Program Files\WindowsApps` from a mounted
WIM, which leaves the provisioning database inconsistent. For true offline
component removal, the guide points to DISM in a Windows VM, NTLite or MSMG
Toolkit, and explains the trade-offs.

## Profiles

| Profile | What changes | Intended use |
| --- | --- | --- |
| `safe` | Unattended setup, cache cleanup, recompressed WIM | Daily driver, maximum compatibility |
| `lean` | `safe` + consumer AppX removal and telemetry policies; Store, Defender and Update stay | Recommended |
| `micro` | `lean` + Store, Xbox, OneDrive, search/SysMain, optional WinRE removal | Experimental, requires `--experimental` |

## Implementation phases

1. **Toolkit**
   - Add `windows/shell.nix`, `build-win11.sh`, `render-unattend.py`,
     `templates/autounattend.xml.in`, `templates/SetupComplete.cmd.in`, and
     `scripts/SetupComplete.ps1`.
   - Keep all destructive file deletion inside the extracted image or in the
     first-boot profile, never against a live system.
2. **Documentation**
   - Write the English guide with commands, warnings, validation and
     troubleshooting.
   - Translate it into German, preserving commands and technical terms.
3. **Website**
   - Enable the `de` locale and locale switcher.
   - Add the guide to the sidebar.
   - Add `/windows` landing page and a homepage teaser.
   - Update footer/navbar metadata.
4. **Verification**
   - `bash -n windows/build-win11.sh`
   - `python3 -m py_compile windows/render-unattend.py`
   - Render a sample `autounattend.xml` and validate it with `xmllint`.
   - `cd website && npm run build`
   - Check that English and German routes are generated.

## Verification performed

| Check | Result |
| --- | --- |
| `bash -n windows/build-win11.sh` | passed |
| `python3 -m py_compile windows/render-unattend.py` | passed |
| Render `autounattend.xml` and `xmllint --noout` | passed |
| PowerShell parser on `SetupComplete.ps1` | passed |
| `wimlib-imagex` capture/export/apply/optimize/verify smoke test | passed |
| `xorriso` ISO repack smoke test | passed; BIOS + UEFI El Torito entries reported |
| End-to-end `build-win11.sh` against a synthetic ISO | passed; bootable ISO produced with BIOS/UEFI entries, `autounattend.xml`, and `$OEM$` scripts |
| `cd website && npm run build` | passed for `en` and `de` |
| English guide route | `/nixos/docs/guides/windows-11-slim-image` generated |
| German guide route | `/nixos/de/docs/guides/windows-11-slim-image` generated |
| Marketing pages | `/nixos/windows` and `/nixos/de/windows` generated |

The end-to-end flow was exercised against a synthetic ISO. A real Windows 11
build was not run because it requires a multi-gigabyte, properly licensed source
ISO; boot-time Windows Setup behaviour still needs validation on the target
build.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Aggressive removal breaks Windows Update or drivers | Keep a `safe` profile; document unsupported changes; test in a VM |
| AppX removal by deleting files corrupts provisioning | Remove packages through `Remove-AppxProvisionedPackage` at first boot |
| Unattended XML exposes a password | Generate a random password by default; warn about empty passwords |
| `install.wim` grows beyond 4 GiB | ISO level 3 and `dd`/Ventoy; document FAT32 split caveat |
| Windows 11 hardware bypass changes between builds | Keep bypass commands isolated and test on the target build |
| NixOS cannot run DISM natively | Use wimlib for media assembly; document Windows VM/DISM for component servicing |

## Acceptance criteria

- A reader can run one documented command on NixOS and produce a bootable ISO.
- The guide states clearly what the toolkit does not remove and why.
- The English and German guides contain the same steps.
- `npm run build` succeeds and emits both `/docs/guides/windows-11-slim-image`
  and `/de/docs/guides/windows-11-slim-image`.
- The homepage and `/windows` page link to the guide in both locales.
