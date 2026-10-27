#!/usr/bin/env python3
"""Install Valve's current SteamCMD packages from its reachable media feed."""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import stat
import tempfile
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath


MANIFEST_URL = "http://media.steampowered.com/client/steam_cmd_linux"
PACKAGE_URL = "http://media.steampowered.com/client/{}"
PACKAGE_PATTERN = re.compile(
    r'"(?P<name>[^"]+)"\s*\{\s*'
    r'"file"\s*"(?P<file>[^"]+)"\s*'
    r'"size"\s*"(?P<size>[0-9]+)"\s*'
    r'"sha2"\s*"(?P<sha256>[0-9a-fA-F]{64})"',
)
REQUIRED_PACKAGES = {
    "steamcmd_public_all",
    "steamcmd_bins_linux",
    "steamcmd_siteserverui_linux",
    "steamcmd_linux",
}


def fetch(url: str, destination: Path, expected_size: int | None = None) -> tuple[int, str]:
    request = urllib.request.Request(url, headers={"User-Agent": "pz-arm64-steamcmd-bootstrap/1"})
    digest = hashlib.sha256()
    total = 0
    with urllib.request.urlopen(request, timeout=60) as response, destination.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            total += len(chunk)
            if expected_size is not None and total > expected_size:
                raise RuntimeError(f"{url} exceeded its manifest size of {expected_size} bytes")
            digest.update(chunk)
            output.write(chunk)
    return total, digest.hexdigest()


def package_records(manifest: str) -> list[dict[str, str | int]]:
    records = [
        {
            "name": match.group("name"),
            "file": match.group("file"),
            "size": int(match.group("size")),
            "sha256": match.group("sha256").lower(),
        }
        for match in PACKAGE_PATTERN.finditer(manifest)
    ]
    found = {str(record["name"]) for record in records}
    missing = REQUIRED_PACKAGES - found
    if missing:
        raise RuntimeError(f"SteamCMD manifest is missing packages: {', '.join(sorted(missing))}")
    return [record for record in records if str(record["name"]) in REQUIRED_PACKAGES]


def safe_destination(root: Path, relative: str) -> Path:
    path = PurePosixPath(relative)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise RuntimeError(f"unsafe path in SteamCMD package: {relative!r}")
    target = root.joinpath(*path.parts)
    if not target.parent.resolve().is_relative_to(root.resolve()):
        raise RuntimeError(f"package path escapes SteamCMD directory: {relative!r}")
    return target


def extract_package(archive: Path, root: Path) -> None:
    with zipfile.ZipFile(archive) as package:
        for member in package.infolist():
            target = safe_destination(root, member.filename)
            mode = member.external_attr >> 16
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                if stat.S_IMODE(mode):
                    target.chmod(stat.S_IMODE(mode))
                continue

            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.parent.resolve().is_relative_to(root.resolve()):
                raise RuntimeError(f"package path traverses a link: {member.filename!r}")
            if stat.S_ISLNK(mode):
                link = package.read(member).decode("utf-8")
                resolved_link = Path(os.path.normpath(target.parent / link))
                if not resolved_link.is_relative_to(root.resolve()):
                    raise RuntimeError(f"package link escapes SteamCMD directory: {member.filename!r}")
                target.symlink_to(link)
                continue

            with package.open(member) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            target.chmod(stat.S_IMODE(mode) or 0o644)


def main() -> None:
    root = Path("/steamcmd-root/opt/steamcmd")
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="steamcmd-bootstrap-") as temp_dir:
        work = Path(temp_dir)
        manifest_path = work / "steam_cmd_linux.manifest"
        _, _ = fetch(MANIFEST_URL, manifest_path)
        manifest = manifest_path.read_text(encoding="utf-8")
        records = package_records(manifest)

        for record in records:
            file_name = str(record["file"])
            if not re.fullmatch(r"[A-Za-z0-9._-]+", file_name):
                raise RuntimeError(f"invalid SteamCMD package filename: {file_name!r}")
            archive = work / file_name
            print(f"Downloading Valve SteamCMD package {file_name}", flush=True)
            size, sha256 = fetch(PACKAGE_URL.format(file_name), archive, int(record["size"]))
            if size != record["size"] or sha256 != record["sha256"]:
                raise RuntimeError(f"SteamCMD package integrity check failed: {file_name}")
            extract_package(archive, root)

        package_dir = root / "package"
        package_dir.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(manifest_path, package_dir / "steam_cmd_linux.manifest")
        (root / "steam.cfg").write_text("BootStrapperInhibitAll=enable\n", encoding="ascii")

    steamcmd = root / "linux32/steamcmd"
    if not steamcmd.is_file():
        raise RuntimeError("Valve SteamCMD packages did not provide linux32/steamcmd")
    steamcmd.chmod(steamcmd.stat().st_mode | 0o111)
    print("Installed verified Valve SteamCMD packages; self-update is disabled", flush=True)


if __name__ == "__main__":
    main()
