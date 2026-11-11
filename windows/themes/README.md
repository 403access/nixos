# Windows theme catalog

The Windows image builder can install one or more third-party Windows themes and
register them under **Settings → Personalization → Themes**. The first theme is
applied automatically at first logon; the others remain selectable.

Theme packs are not vendored in this repository. Some artists, including niivu,
make downloads available only to watchers or under a non-redistribution licence.
Download the theme from the artist, then point the build at the archive.

## Catppuccin for Windows 11 (niivu)

1. Open <https://www.deviantart.com/niivu/art/Catppuccin-for-Windows-11-1076249390>.
2. Watch the artist to reveal the download button, then download the archive.
3. Build with the catalog entry:

   ```bash
   ./build-win11-docker.sh --iso ~/Downloads/Win11.iso --profile lean \
     --theme catppuccin-niivu --theme-dir ~/Downloads \
     --theme-default "Catppuccin Mocha"
   ```

   The archive may also be placed in `windows/themes/downloads/`, which is
   searched by default and ignored by Git.

   Alternatively, pass the archive directly:

   ```bash
   ./build-win11-docker.sh --iso ~/Downloads/Win11.iso --profile lean \
     --theme-archive ~/Downloads/catppuccin-for-windows-11.zip
   ```

The build installs every `.theme` file from the pack and selects one with
`--theme-default` (a substring of the display name or file name). Without that
option the catalog default (`*Mocha*`) is used, falling back to the first theme
alphabetically.

## How themes are applied

- The archive is extracted and its `.theme` files plus the accompanying
  `Resources\Themes` folder structure are copied into the offline image.
- SecureUxTheme v4.0.0 is downloaded from its GitHub release, verified against a
  pinned SHA-256, and staged offline: `SecureUxTheme4.dll` and
  `ThemeUiProxy.dll` are copied into `System32`/`SysWOW64`, and the
  `Image File Execution Options\winlogon.exe` hook values are written to the
  offline `SOFTWARE` hive. No MSI runs during Windows Setup.
- A first-logon `RunOnce` entry applies the selected `.theme` file to the first
  user who logs in. The other installed themes appear in Settings.
- Pass `--no-theme-patcher` to install only the theme files. Wallpaper, colours
  and cursors can still apply, but Windows will reject unsigned `.msstyles`
  visual styles.
- Pass `--theme-patcher-msi PATH` to use a locally downloaded SecureUxTheme MSI
  instead of downloading it during the build (useful offline).

SecureUxTheme is third-party software (LGPL-2.1). Review the project and its
release hashes before using it:

- <https://github.com/namazso/SecureUxTheme>

SecureUxTheme v4.0.0 is tested through Windows 11 24H2. Newer Windows builds may
need a newer patcher; pass `--theme-patcher-msi PATH` or use
`--no-theme-patcher` if the hook is not compatible.

## Adding another theme

Add an entry to `catalog.json`:

```json
{
  "id": "my-theme",
  "name": "My Theme",
  "author": "Artist",
  "page": "https://example.invalid/my-theme",
  "license": "Check the artist's terms",
  "archives": ["*my-theme*.zip", "*my-theme*.rar", "*my-theme*.7z"],
  "exclude": ["*windows*10*"],
  "default": "*Dark*",
  "downloadHint": "Download the archive from the artist."
}
```

Then run the build with `--theme my-theme --theme-dir ~/Downloads`.

`archives` are case-insensitive glob patterns matched against the file name.
`exclude` wins over `archives`. `default` optionally selects the theme applied
at first logon; `--theme-default` overrides it.

## What is not installed automatically

- 7TSP icon packs and other system-resource replacements. They modify protected
  system files and need their own patcher/reboot workflow.
- Rainmeter skins, docks, Start menu replacements and other desktop utilities.
- Fonts bundled inside a theme folder. Windows can see them only after they are
  registered; install them manually if the theme's readme asks for it.

## Safety

Third-party `.msstyles`, DLLs, cursors and wallpapers are untrusted binary and
image data. Use themes from artists you trust, keep a known-good Windows image,
and test the result in a VM. Custom themes are unsupported by Microsoft and can
cause login loops or broken updates. To recover, boot into another account or
Safe Mode, switch to a default theme, or remove the SecureUxTheme IFEO values
and DLLs.
