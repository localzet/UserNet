#!/usr/bin/env python3
"""Build, verify, and publish a UserNet OTA bundle."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import time
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit


MAX_ARTIFACT_BYTES = 512 * 1024 * 1024
MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024
PLATFORMS = ("android", "linux", "windows", "macos")
OTA_HOST = "www.userlay.com"

MANIFEST_FIELDS = {
    "android": (("apkUrl", "sha256", ".apk"),),
    "linux": (("debUrl", "sha256", ".deb"),),
    "windows": (("installerUrl", "sha256", ".exe"),),
    "macos": (
        ("dmgArm64Url", "sha256Arm64", ".dmg"),
        ("dmgAmd64Url", "sha256Amd64", ".dmg"),
    ),
}


class OtaError(Exception):
    pass


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _expected_name(platform: str, version: str, build: int, arch: str | None = None) -> str:
    stem = f"usernet-stable-{version}-{build}"
    if platform == "android":
        return f"{stem}.apk"
    if platform == "linux":
        return f"{stem}.deb"
    if platform == "windows":
        return f"{stem}-windows-amd64-setup.exe"
    if platform == "macos" and arch in {"arm64", "amd64"}:
        return f"{stem}-macos-{arch}.dmg"
    raise OtaError("Unsupported OTA artifact")


def _write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def prepare_bundle(
    *,
    version: str,
    build: int,
    notes: str,
    inputs: dict[str, Path],
    output: Path,
) -> tuple[Path, Path]:
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise OtaError("Version must be X.Y.Z")
    if not 1_000_000_000 <= build <= 9_999_999_999:
        raise OtaError("Build must be a 10-digit positive integer")
    if len(notes) > 20_000:
        raise OtaError("Release notes are too long")
    if set(inputs) != {"android", "linux", "windows", "macos-arm64", "macos-amd64"}:
        raise OtaError("The release must contain all five platform artifacts")

    output.mkdir(parents=True, exist_ok=False)
    bundle = output / "bundle"
    release_assets = output / "release-assets"
    bundle.mkdir()
    release_assets.mkdir()
    manifests: dict[str, dict] = {}

    asset_specs = (
        ("android", "", "apkUrl", "sha256"),
        ("linux", "", "debUrl", "sha256"),
        ("windows", "", "installerUrl", "sha256"),
        ("macos", "arm64", "dmgArm64Url", "sha256Arm64"),
        ("macos", "amd64", "dmgAmd64Url", "sha256Amd64"),
    )
    for platform, arch, url_field, checksum_field in asset_specs:
        input_key = f"{platform}-{arch}" if arch else platform
        source = inputs[input_key]
        if source.is_symlink() or not source.is_file():
            raise OtaError(f"Missing regular build artifact: {input_key}")
        size = source.stat().st_size
        if size <= 0 or size > MAX_ARTIFACT_BYTES:
            raise OtaError(f"Invalid build artifact size: {input_key}")

        name = _expected_name(platform, version, build, arch or None)
        target = bundle / platform / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        os.chmod(target, 0o644)
        checksum = _sha256(target)
        manifest = manifests.setdefault(
            platform,
            {"version": version, "build": build, "notes": notes},
        )
        manifest[url_field] = f"https://{OTA_HOST}/usernet-updates/{platform}/{name}"
        manifest[checksum_field] = checksum
        shutil.copyfile(target, release_assets / name)

    for platform, manifest in manifests.items():
        _write_json(bundle / platform / "stable.json", manifest)
    _write_json(bundle / "bundle.json", {"version": version, "build": build})
    verify_bundle(bundle)

    checksum_lines = [
        f"{_sha256(path)}  {path.name}"
        for path in sorted(release_assets.iterdir())
        if path.is_file()
    ]
    (release_assets / "SHA256SUMS.txt").write_text(
        "\n".join(checksum_lines) + "\n",
        encoding="ascii",
    )
    archive = output / "ota-bundle.tar.gz"
    with tarfile.open(archive, mode="w:gz") as tar:
        for path in sorted(bundle.rglob("*")):
            if path.is_file():
                tar.add(path, arcname=path.relative_to(bundle).as_posix(), recursive=False)
    return archive, release_assets


def verify_bundle(bundle: Path) -> tuple[str, int, list[tuple[str, str, str]]]:
    if bundle.is_symlink() or not bundle.is_dir():
        raise OtaError("OTA bundle directory is missing")
    try:
        metadata = json.loads((bundle / "bundle.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise OtaError("Invalid bundle metadata") from error
    if not isinstance(metadata, dict) or set(metadata) != {"version", "build"}:
        raise OtaError("Invalid bundle metadata")
    version = metadata.get("version")
    build = metadata.get("build")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise OtaError("Invalid bundle version")
    if not isinstance(build, int) or not 1_000_000_000 <= build <= 9_999_999_999:
        raise OtaError("Invalid bundle build")

    expected_roots = {"bundle.json", *PLATFORMS}
    if {entry.name for entry in bundle.iterdir()} != expected_roots:
        raise OtaError("Unexpected files in OTA bundle")

    artifacts: list[tuple[str, str, str]] = []
    for platform in PLATFORMS:
        platform_dir = bundle / platform
        if platform_dir.is_symlink() or not platform_dir.is_dir():
            raise OtaError(f"Missing platform bundle: {platform}")
        manifest_path = platform_dir / "stable.json"
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise OtaError(f"Invalid {platform} manifest") from error

        expected_keys = {"version", "build", "notes"}
        for url_field, checksum_field, _ in MANIFEST_FIELDS[platform]:
            expected_keys.update((url_field, checksum_field))
        if not isinstance(manifest, dict) or set(manifest) != expected_keys:
            raise OtaError(f"Invalid {platform} manifest fields")
        if manifest.get("version") != version or manifest.get("build") != build:
            raise OtaError(f"Version mismatch in {platform} manifest")
        if not isinstance(manifest.get("notes"), str) or len(manifest["notes"]) > 20_000:
            raise OtaError(f"Invalid release notes in {platform} manifest")

        expected_files = {"stable.json"}
        for index, (url_field, checksum_field, extension) in enumerate(MANIFEST_FIELDS[platform]):
            arch = ("arm64", "amd64")[index] if platform == "macos" else None
            name = _expected_name(platform, version, build, arch)
            url = urlsplit(str(manifest.get(url_field, "")))
            expected_path = f"/usernet-updates/{platform}/{name}"
            if (
                url.scheme != "https"
                or url.hostname != OTA_HOST
                or url.port is not None
                or url.username is not None
                or url.password is not None
                or url.query
                or url.fragment
                or url.path != expected_path
                or not name.endswith(extension)
            ):
                raise OtaError(f"Untrusted artifact URL in {platform} manifest")

            checksum = manifest.get(checksum_field)
            if not isinstance(checksum, str) or not re.fullmatch(r"[a-f0-9]{64}", checksum):
                raise OtaError(f"Invalid artifact checksum in {platform} manifest")
            artifact = platform_dir / name
            if artifact.is_symlink() or not artifact.is_file():
                raise OtaError(f"Missing artifact for {platform}")
            size = artifact.stat().st_size
            if size <= 0 or size > MAX_ARTIFACT_BYTES or _sha256(artifact) != checksum:
                raise OtaError(f"Artifact verification failed for {platform}")
            expected_files.add(name)
            artifacts.append((platform, name, checksum))

        if {entry.name for entry in platform_dir.iterdir()} != expected_files:
            raise OtaError(f"Unexpected files in {platform} bundle")
    return version, build, artifacts


def _atomic_write(destination: Path, content: bytes) -> None:
    fd, temporary_name = tempfile.mkstemp(prefix=".stable-", dir=destination.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, destination)
        directory_fd = os.open(destination.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if temporary.exists():
            temporary.unlink()


def _state_root(releases_root: Path) -> Path:
    return releases_root.parent / ".usernet-ota-state"


def apply_bundle(bundle: Path, releases_root: Path) -> bool:
    version, build, artifacts = verify_bundle(bundle)
    if releases_root.is_symlink():
        raise OtaError("OTA releases root must not be a symbolic link")
    releases_root.mkdir(parents=True, exist_ok=True)
    state_root = _state_root(releases_root)
    if state_root.is_symlink():
        raise OtaError("OTA state directory must not be a symbolic link")
    state_root.mkdir(mode=0o700, exist_ok=True)
    if not state_root.is_dir():
        raise OtaError("OTA state path must be a directory")
    lock_path = state_root / "publish.lock"
    if lock_path.is_symlink():
        raise OtaError("OTA publish lock must not be a symbolic link")
    with lock_path.open("a+b") as lock:
        os.chmod(lock_path, 0o660)
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        old_manifests: dict[str, bytes | None] = {}
        new_manifests: dict[str, bytes] = {}
        changed_platforms: list[str] = []

        for platform in PLATFORMS:
            target_dir = releases_root / platform
            if target_dir.is_symlink():
                raise OtaError(f"OTA platform directory must not be a symbolic link: {platform}")
            if target_dir.exists() and not target_dir.is_dir():
                raise OtaError(f"OTA platform path must be a directory: {platform}")
            target_manifest = releases_root / platform / "stable.json"
            if target_manifest.is_symlink():
                raise OtaError(f"Existing {platform} manifest must not be a symbolic link")
            new_content = (bundle / platform / "stable.json").read_bytes()
            new_manifests[platform] = new_content
            old_content = target_manifest.read_bytes() if target_manifest.exists() else None
            old_manifests[platform] = old_content
            if old_content is not None:
                try:
                    old_build = int(json.loads(old_content).get("build", 0))
                except (ValueError, json.JSONDecodeError):
                    raise OtaError(f"Existing {platform} manifest is invalid")
                if old_build > build:
                    raise OtaError(f"Refusing to replace newer {platform} release")
                if old_build == build and old_content != new_content:
                    raise OtaError(f"Refusing to overwrite immutable {platform} manifest")

        for platform, name, checksum in artifacts:
            source = bundle / platform / name
            target_dir = releases_root / platform
            if target_dir.is_symlink():
                raise OtaError(f"OTA platform directory must not be a symbolic link: {platform}")
            target_dir.mkdir(parents=True, exist_ok=True)
            target = target_dir / name
            if target.exists():
                if target.is_symlink() or not target.is_file() or _sha256(target) != checksum:
                    raise OtaError(f"Refusing to overwrite immutable artifact: {name}")
                continue
            fd, temporary_name = tempfile.mkstemp(prefix=".artifact-", dir=target_dir)
            temporary = Path(temporary_name)
            try:
                with os.fdopen(fd, "wb") as destination, source.open("rb") as original:
                    shutil.copyfileobj(original, destination)
                    destination.flush()
                    os.fsync(destination.fileno())
                os.chmod(temporary, 0o644)
                os.replace(temporary, target)
            finally:
                if temporary.exists():
                    temporary.unlink()

        rollback_root = state_root / "rollback"
        if rollback_root.is_symlink():
            raise OtaError("OTA rollback directory must not be a symbolic link")
        rollback_dir = rollback_root / f"{build}-{time.time_ns()}"
        rollback_dir.mkdir(parents=True, exist_ok=True)
        for platform, content in old_manifests.items():
            if content is not None:
                backup = rollback_dir / platform / "stable.json"
                backup.parent.mkdir(parents=True, exist_ok=True)
                backup.write_bytes(content)
                os.chmod(backup, 0o644)

        try:
            for platform in PLATFORMS:
                target = releases_root / platform / "stable.json"
                if old_manifests[platform] == new_manifests[platform]:
                    continue
                _atomic_write(target, new_manifests[platform])
                changed_platforms.append(platform)
        except BaseException:
            for platform in reversed(changed_platforms):
                target = releases_root / platform / "stable.json"
                old_content = old_manifests[platform]
                if old_content is None:
                    target.unlink(missing_ok=True)
                else:
                    _atomic_write(target, old_content)
            raise
        return bool(changed_platforms)


def _extract_archive(archive_path: Path, destination: Path) -> None:
    total_bytes = 0
    file_count = 0
    allowed_roots = {"bundle.json", *PLATFORMS}
    with tarfile.open(archive_path, mode="r:gz") as archive:
        for member in archive:
            relative = PurePosixPath(member.name)
            if (
                relative.is_absolute()
                or not relative.parts
                or any(part in {"", ".", ".."} for part in relative.parts)
                or relative.parts[0] not in allowed_roots
                or not member.isfile()
                or member.issym()
                or member.islnk()
            ):
                raise OtaError("Unsafe OTA archive entry")
            if len(relative.parts) > 2 or (relative.parts[0] == "bundle.json" and len(relative.parts) != 1):
                raise OtaError("Unexpected OTA archive path")
            if relative.parts[0] in PLATFORMS and len(relative.parts) != 2:
                raise OtaError("Unexpected OTA archive path")
            file_count += 1
            total_bytes += member.size
            if file_count > 16 or member.size > MAX_ARTIFACT_BYTES or total_bytes > MAX_ARCHIVE_BYTES:
                raise OtaError("OTA archive exceeds size limits")
            target = destination.joinpath(*relative.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise OtaError("Invalid OTA archive entry")
            with source, target.open("xb") as output:
                remaining = member.size
                while remaining:
                    chunk = source.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise OtaError("Truncated OTA archive entry")
                    output.write(chunk)
                    remaining -= len(chunk)
                output.flush()
                os.fsync(output.fileno())


def receive_and_apply(releases_root: Path) -> bool:
    if releases_root.is_symlink():
        raise OtaError("OTA releases root must not be a symbolic link")
    releases_root.mkdir(parents=True, exist_ok=True)
    state_root = _state_root(releases_root)
    if state_root.is_symlink():
        raise OtaError("OTA state directory must not be a symbolic link")
    state_root.mkdir(mode=0o700, exist_ok=True)
    incoming = state_root / "incoming"
    if incoming.is_symlink():
        raise OtaError("OTA incoming directory must not be a symbolic link")
    incoming.mkdir(mode=0o700, exist_ok=True)
    if not incoming.is_dir():
        raise OtaError("OTA incoming path must be a directory")
    with tempfile.TemporaryDirectory(prefix="ota-", dir=incoming) as temporary_dir:
        temporary = Path(temporary_dir)
        archive_path = temporary / "bundle.tar.gz"
        received = 0
        with archive_path.open("xb") as output:
            for chunk in iter(lambda: sys.stdin.buffer.read(1024 * 1024), b""):
                received += len(chunk)
                if received > MAX_ARCHIVE_BYTES:
                    raise OtaError("OTA archive exceeds size limits")
                output.write(chunk)
        bundle = temporary / "bundle"
        bundle.mkdir()
        _extract_archive(archive_path, bundle)
        return apply_bundle(bundle, releases_root)


def _prepare_command(args: argparse.Namespace) -> None:
    notes = args.notes.read_text(encoding="utf-8")
    inputs = {
        "android": args.android,
        "linux": args.linux,
        "windows": args.windows,
        "macos-arm64": args.macos_arm64,
        "macos-amd64": args.macos_amd64,
    }
    archive, release_assets = prepare_bundle(
        version=args.version,
        build=args.build,
        notes=notes,
        inputs=inputs,
        output=args.output,
    )
    print(f"Prepared verified OTA bundle for {args.version} ({args.build}).")
    print(f"Bundle: {archive}")
    print(f"Release assets: {release_assets}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("prepare")
    prepare.add_argument("--version", required=True)
    prepare.add_argument("--build", required=True, type=int)
    prepare.add_argument("--notes", required=True, type=Path)
    prepare.add_argument("--android", required=True, type=Path)
    prepare.add_argument("--linux", required=True, type=Path)
    prepare.add_argument("--windows", required=True, type=Path)
    prepare.add_argument("--macos-arm64", required=True, type=Path)
    prepare.add_argument("--macos-amd64", required=True, type=Path)
    prepare.add_argument("--output", required=True, type=Path)

    verify = commands.add_parser("verify")
    verify.add_argument("bundle", type=Path)

    receive = commands.add_parser("receive")
    receive.add_argument(
        "--root",
        type=Path,
        default=Path("/opt/usernet-updates-origin/releases"),
    )

    args = parser.parse_args()
    try:
        if args.command == "prepare":
            _prepare_command(args)
        elif args.command == "verify":
            version, build, artifacts = verify_bundle(args.bundle)
            print(f"Verified {version} ({build}): {len(artifacts)} artifacts.")
        else:
            changed = receive_and_apply(args.root)
            print("Published verified UserNet OTA bundle." if changed else "OTA bundle already published.")
    except (OtaError, OSError, tarfile.TarError) as error:
        print(f"OTA release rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
