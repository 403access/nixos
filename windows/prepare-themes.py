#!/usr/bin/env python3
"""Stage Windows theme packs into an applied image and write a first-logon config."""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import shutil
import subprocess
from pathlib import Path, PureWindowsPath

THEMES_REL = Path("Windows/Resources/Themes")
SOFTWARE_REL = Path("Windows/System32/config/SOFTWARE")
SYSTEM32_REL = Path("Windows/System32")
SYSWOW64_REL = Path("Windows/SysWOW64")
IFEO_PARENT = r"Microsoft\Windows NT\CurrentVersion\Image File Execution Options"
IFEO_KEY = IFEO_PARENT + r"\winlogon.exe"
EXPECTED_IFEO = {
    '"VerifierDlls"="SecureUxTheme4.dll"',
    '"GlobalFlag"=dword:00000100',
}


def log(message: str) -> None:
    print(f"  {message}", flush=True)


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def safe_name(value: str) -> str:
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip(".-")
    return name or "theme"


def load_catalog(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"theme catalog not found: {path}")
    except json.JSONDecodeError as exc:
        fail(f"invalid theme catalog {path}: {exc}")
    if not isinstance(data.get("themes"), list):
        fail(f"theme catalog {path} has no themes array")
    return data


def find_entry(catalog: dict, theme_id: str) -> dict:
    for entry in catalog["themes"]:
        if entry.get("id") == theme_id:
            return entry
    known = ", ".join(sorted(str(e.get("id")) for e in catalog["themes"]))
    fail(f"unknown theme {theme_id!r}; known themes: {known}")


def matches_archive(name: str, entry: dict) -> bool:
    lower = name.lower()
    includes = [p.lower() for p in entry.get("archives", [])]
    excludes = [p.lower() for p in entry.get("exclude", [])]
    if any(fnmatch.fnmatch(lower, pattern) for pattern in excludes):
        return False
    return any(fnmatch.fnmatch(lower, pattern) for pattern in includes)


def find_archive(entry: dict, theme_dirs: list[Path]) -> Path:
    matches: list[Path] = []
    for directory in theme_dirs:
        if not directory.is_dir():
            continue
        for path in directory.rglob("*"):
            if path.is_file() and matches_archive(path.name, entry):
                matches.append(path)
    unique = sorted({p.resolve() for p in matches})
    theme_id = entry.get("id", "theme")
    if not unique:
        page = entry.get("page") or entry.get("downloadPage") or "(no page recorded)"
        hint = entry.get("downloadHint") or (
            "Download the archive from the artist and place it in "
            "windows/themes/downloads/ or pass --theme-archive."
        )
        fail(
            f"no archive found for {theme_id!r}.\n"
            f"  Source: {page}\n"
            f"  {hint}"
        )
    if len(unique) > 1:
        listing = "\n".join(f"  {p}" for p in unique)
        fail(
            f"more than one archive matches {theme_id!r}; use --theme-archive "
            f"to pick one:\n{listing}"
        )
    return unique[0]


def match_entry_for_archive(catalog: dict, archive: Path) -> dict | None:
    found = [e for e in catalog["themes"] if matches_archive(archive.name, e)]
    return found[0] if len(found) == 1 else None


def extract_archive(archive: Path, destination: Path, seven_z: str) -> Path:
    if archive.is_dir():
        return archive
    destination.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.run(
            [seven_z, "x", "-y", f"-o{destination}", str(archive)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError:
        fail(f"could not extract theme archive: {archive}")
    return destination


def visual_style_path(theme_file: Path) -> PureWindowsPath | None:
    """Return the [VisualStyles] Path relative to Resources\\Themes, if present."""
    try:
        text = theme_file.read_text(encoding="utf-8-sig", errors="replace")
    except OSError:
        return None

    section = ""
    path_value = ""
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip().lower()
            continue
        if section == "visualstyles" and line.lower().startswith("path="):
            path_value = line.split("=", 1)[1].strip()
            break

    if not path_value:
        return None

    value = path_value.replace("/", "\\")
    lower = value.lower()
    marker = "\\themes\\"
    index = lower.find(marker)
    if index >= 0:
        relative = value[index + len(marker) :]
    elif lower.startswith("themes\\"):
        relative = value[len("themes\\") :]
    else:
        return None

    parts = [part for part in relative.split("\\") if part]
    if not parts:
        return None
    return PureWindowsPath(*parts)


def find_pack_root(extracted: Path) -> Path:
    theme_files = sorted(
        p for p in extracted.rglob("*") if p.is_file() and p.suffix.lower() == ".theme"
    )
    if not theme_files:
        fail(
            f"no .theme files found in {extracted}; if the pack contains a nested "
            "archive, extract it and pass the inner archive or directory"
        )

    extracted = extracted.resolve()
    theme_files = [p.resolve() for p in theme_files]
    parents = {p.parent for p in theme_files}
    common = Path(os.path.commonpath([str(p) for p in parents])).resolve()
    if common != extracted and extracted not in common.parents:
        fail(f"refusing to use a theme root outside the extracted pack: {common}")

    # Most packs are rooted at Resources\Themes: the .theme files sit at the
    # root and their VisualStyles path names a sibling folder. Some packs add
    # an extra wrapper directory, and some put the .theme file inside the
    # folder it references. Try the shallowest root that satisfies every
    # VisualStyles path before falling back to the common parent.
    candidates = [extracted, common]
    for theme_file in theme_files:
        for candidate in [theme_file.parent, *theme_file.parent.parents]:
            if candidate == extracted or extracted in candidate.parents:
                candidates.append(candidate)
    ordered: list[Path] = []
    for candidate in sorted(candidates, key=lambda p: len(p.parts)):
        if candidate not in ordered:
            ordered.append(candidate)

    def matches(candidate: Path) -> bool:
        for theme_file in theme_files:
            try:
                theme_file.relative_to(candidate)
            except ValueError:
                return False
            visual_style = visual_style_path(theme_file)
            if visual_style is None:
                continue
            if not candidate.joinpath(*visual_style.parts).is_file():
                return False
        return True

    root = next((candidate for candidate in ordered if matches(candidate)), common)
    if root == common and not matches(root):
        log(
            "could not verify VisualStyles paths in this pack; "
            "preserving the common theme folder"
        )
    return root


def copy_pack(root: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)

    def copy_item(source: Path, target: Path) -> None:
        if source.is_symlink():
            log(f"skipping symlink in theme pack: {source}")
            return
        if source.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            for child in source.iterdir():
                copy_item(child, target / child.name)
            return
        if not source.is_file():
            return
        if target.exists() and target.is_file():
            log(f"replacing existing theme file: {source.name}")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

    for item in root.iterdir():
        if item.name in {"__MACOSX", ".DS_Store"} or item.name.startswith("._"):
            continue
        copy_item(item, destination / item.name)


def read_display_name(theme_file: Path) -> str:
    try:
        text = theme_file.read_text(encoding="utf-8-sig", errors="replace")
    except OSError:
        return theme_file.stem
    in_theme = False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            in_theme = line[1:-1].strip().lower() == "theme"
            continue
        if in_theme and line.lower().startswith("displayname="):
            value = line.split("=", 1)[1].strip()
            if value:
                return value
    return theme_file.stem


def windows_path(relative: Path) -> str:
    base = PureWindowsPath("C:/Windows/Resources/Themes")
    return str(base / PureWindowsPath(*relative.parts))


def collect_theme_files(root: Path, destination: Path) -> list[dict]:
    files: list[dict] = []
    for source in root.rglob("*"):
        if not source.is_file() or source.suffix.lower() != ".theme":
            continue
        relative = source.relative_to(root)
        target = destination / relative
        files.append(
            {
                "path": windows_path(relative),
                "displayName": read_display_name(target),
            }
        )
    files.sort(key=lambda item: (item["displayName"].casefold(), item["path"].casefold()))
    return files


def select_default(files: list[dict], requested: str, fallback_glob: str | None) -> dict:
    if requested:
        needle = requested.casefold()
        matches = [
            f
            for f in files
            if needle in f["displayName"].casefold() or needle in f["path"].casefold()
        ]
        if not matches:
            matches = [
                f
                for f in files
                if fnmatch.fnmatch(f["displayName"].casefold(), needle)
                or fnmatch.fnmatch(PureWindowsPath(f["path"]).name.casefold(), needle)
            ]
        if not matches:
            listing = "\n".join(f"  {f['displayName']} ({f['path']})" for f in files)
            fail(f"no theme file matches --theme-default {requested!r}:\n{listing}")
        exact = [
            f
            for f in matches
            if requested.casefold()
            in {f["displayName"].casefold(), PureWindowsPath(f["path"]).stem.casefold()}
        ]
        if len(exact) == 1:
            return exact[0]
        if len(matches) == 1:
            return matches[0]
        listing = "\n".join(f"  {f['displayName']} ({f['path']})" for f in matches)
        fail(f"--theme-default {requested!r} is ambiguous:\n{listing}")

    if fallback_glob:
        matches = [
            f
            for f in files
            if fnmatch.fnmatch(f["displayName"].casefold(), fallback_glob.casefold())
            or fnmatch.fnmatch(
                PureWindowsPath(f["path"]).name.casefold(), fallback_glob.casefold()
            )
        ]
        if matches:
            return matches[0]
        log(f"catalog default {fallback_glob!r} did not match; using the first theme")
    return files[0]


def stage_patcher(
    image_root: Path,
    msi: Path,
    staging: Path,
    seven_z: str,
    version: str,
) -> None:
    payload = staging / "patcher"
    if payload.exists():
        shutil.rmtree(payload)
    payload.mkdir(parents=True)
    try:
        subprocess.run(
            [seven_z, "x", "-y", f"-o{payload}", str(msi)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError:
        fail(f"could not extract SecureUxTheme MSI: {msi}")

    for name in ("Hook64", "Proxy64", "Hook32", "Proxy32"):
        if not (payload / name).is_file():
            fail(f"SecureUxTheme MSI payload is missing {name}: {msi}")

    system32 = image_root / SYSTEM32_REL
    syswow64 = image_root / SYSWOW64_REL
    if not system32.is_dir():
        fail(f"offline image has no {SYSTEM32_REL}: {image_root}")

    shutil.copy2(payload / "Hook64", system32 / "SecureUxTheme4.dll")
    shutil.copy2(payload / "Proxy64", system32 / "ThemeUiProxy.dll")
    if syswow64.is_dir():
        shutil.copy2(payload / "Hook32", syswow64 / "SecureUxTheme4.dll")
        shutil.copy2(payload / "Proxy32", syswow64 / "ThemeUiProxy.dll")
    else:
        log("SysWOW64 is missing; staged the 64-bit SecureUxTheme payload only")

    software = image_root / SOFTWARE_REL
    if not software.is_file():
        fail(f"offline SOFTWARE hive not found: {software}")

    parent_check = subprocess.run(
        ["hivexget", str(software), IFEO_PARENT],
        capture_output=True,
        text=True,
    )
    if parent_check.returncode != 0:
        fail(
            "offline SOFTWARE hive has no Image File Execution Options key; "
            "pass --no-theme-patcher or use a Windows 11 image"
        )

    existing = subprocess.run(
        ["hivexget", str(software), IFEO_KEY],
        capture_output=True,
        text=True,
    )
    if existing.returncode == 0:
        values = {line.strip() for line in existing.stdout.splitlines() if line.strip()}
        if values == EXPECTED_IFEO:
            log(f"SecureUxTheme {version} is already staged in {software}")
        elif values:
            fail(
                "the offline SOFTWARE hive already has Image File Execution Options "
                f"values for winlogon.exe; refusing to replace them:\n  "
                + "\n  ".join(sorted(values))
            )
        else:
            script = [
                f"cd \\{IFEO_KEY}",
                "setval 2",
                "VerifierDlls",
                "string:SecureUxTheme4.dll",
                "GlobalFlag",
                "dword:0x00000100",
                "commit",
                "quit",
            ]
            subprocess.run(
                ["hivexsh", "-w", str(software)],
                input="\n".join(script) + "\n",
                text=True,
                check=True,
            )
    else:
        script = [
            f"cd \\{IFEO_PARENT}",
            "add winlogon.exe",
            "cd winlogon.exe",
            "setval 2",
            "VerifierDlls",
            "string:SecureUxTheme4.dll",
            "GlobalFlag",
            "dword:0x00000100",
            "commit",
            "quit",
        ]
        subprocess.run(
            ["hivexsh", "-w", str(software)],
            input="\n".join(script) + "\n",
            text=True,
            check=True,
        )

    verify = subprocess.run(
        ["hivexget", str(software), IFEO_KEY],
        capture_output=True,
        text=True,
    )
    if verify.returncode != 0 or "SecureUxTheme4.dll" not in verify.stdout:
        fail("failed to verify the SecureUxTheme Image File Execution Options hook")

    log(f"staged SecureUxTheme {version} in the offline image")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--image-root", type=Path, required=True)
    parser.add_argument("--staging", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--theme", action="append", default=[])
    parser.add_argument("--archive", action="append", default=[])
    parser.add_argument("--theme-dir", action="append", default=[])
    parser.add_argument("--default", default="")
    parser.add_argument("--patcher-msi", type=Path, default=None)
    parser.add_argument("--patcher-version", default="unknown")
    parser.add_argument("--seven-z", default="7z")
    args = parser.parse_args()

    catalog = load_catalog(args.catalog)
    image_root = args.image_root.resolve()
    if not image_root.is_dir():
        fail(f"image root not found: {image_root}")

    theme_dirs = [Path(d).expanduser().resolve() for d in args.theme_dir]
    if not theme_dirs:
        theme_dirs = [
            (args.catalog.parent / "downloads").resolve(),
            args.catalog.parent.resolve(),
        ]

    selections: list[dict] = []
    seen_archives: set[Path] = set()

    def add_selection(entry: dict | None, archive: Path) -> None:
        resolved = archive.resolve()
        if resolved in seen_archives:
            return
        seen_archives.add(resolved)
        if entry is None:
            entry = {
                "id": safe_name(archive.stem),
                "name": archive.stem,
            }
        selections.append(
            {
                "id": safe_name(str(entry.get("id") or archive.stem)),
                "name": str(entry.get("name") or entry.get("id") or archive.stem),
                "entry": entry,
                "archive": resolved,
            }
        )

    for theme_id in args.theme:
        for item in theme_id.split(","):
            item = item.strip()
            if not item:
                continue
            entry = find_entry(catalog, item)
            add_selection(entry, find_archive(entry, theme_dirs))

    for archive_value in args.archive:
        archive = Path(archive_value).expanduser()
        if not archive.exists():
            fail(f"theme archive not found: {archive}")
        entry = match_entry_for_archive(catalog, archive)
        add_selection(entry, archive)

    if not selections:
        fail("no themes were selected; pass --theme or --theme-archive")

    # Make theme ids unique so two archives with the same stem do not collide.
    used_ids: set[str] = set()
    for selection in selections:
        base = selection["id"]
        candidate = base
        counter = 2
        while candidate in used_ids:
            candidate = f"{base}-{counter}"
            counter += 1
        selection["id"] = candidate
        used_ids.add(candidate)

    themes_destination = image_root / THEMES_REL
    staging_root = args.staging.resolve()
    staging_root.mkdir(parents=True, exist_ok=True)

    installed: list[dict] = []
    for selection in selections:
        archive = selection["archive"]
        work = staging_root / selection["id"]
        if archive.is_dir():
            extracted = archive
        else:
            if work.exists():
                shutil.rmtree(work)
            work.mkdir(parents=True)
            extracted = extract_archive(archive, work, args.seven_z)
        root = find_pack_root(extracted)
        log(f"installing {selection['name']} from {archive.name}")
        copy_pack(root, themes_destination)
        files = collect_theme_files(root, themes_destination)
        if not files:
            fail(f"no .theme files found after installing {archive}")
        selection["files"] = files
        installed.extend(files)

    fallback_glob = None
    for selection in selections:
        candidate = selection["entry"].get("default")
        if candidate:
            fallback_glob = str(candidate)
            break

    default = select_default(installed, args.default, fallback_glob)

    config = {
        "version": 1,
        "themes": [
            {
                "id": selection["id"],
                "name": selection["name"],
                "files": selection["files"],
            }
            for selection in selections
        ],
        "default": default["path"],
        "defaultDisplayName": default["displayName"],
    }

    if args.patcher_msi is not None:
        msi = args.patcher_msi.expanduser().resolve()
        if not msi.is_file():
            fail(f"SecureUxTheme MSI not found: {msi}")
        stage_patcher(
            image_root,
            msi,
            staging_root,
            args.seven_z,
            args.patcher_version,
        )
        config["patcher"] = {
            "name": "SecureUxTheme",
            "version": args.patcher_version,
            "staged": True,
        }
    else:
        config["patcher"] = {"name": "SecureUxTheme", "staged": False}

    args.config.parent.mkdir(parents=True, exist_ok=True)
    args.config.write_text(
        json.dumps(config, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    count = len(installed)
    log(f"registered {count} theme file(s) from {len(selections)} pack(s)")
    log(f"default theme: {default['displayName']} ({default['path']})")
    if config["patcher"]["staged"]:
        log(f"theme patcher: SecureUxTheme {args.patcher_version} staged")
    else:
        log("theme patcher: not staged; Windows may ignore custom visual styles")
    print(f"THEME_SUMMARY={default['displayName']} ({count} registered)")


if __name__ == "__main__":
    main()
