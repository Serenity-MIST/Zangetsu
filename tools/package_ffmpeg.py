"""Stage or verify an explicitly supplied, pinned portable FFmpeg distribution.

No downloads or PATH lookup occur here. Supply the distributor's complete
notices and corresponding-source information; a hash is not a license audit.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile


def verify(directory):
    """Reject absent/changed payloads and missing distribution documentation."""
    directory = Path(directory).resolve()
    manifest = json.loads((directory / "distribution.json").read_text(encoding="utf-8"))
    for field in ("version", "binary_origin", "corresponding_source"):
        if not isinstance(manifest.get(field), str) or not manifest[field].strip():
            raise ValueError(f"Missing distribution field: {field}")
    files = manifest.get("files", {})
    notices = manifest.get("notices", [])
    if "ffmpeg.exe" not in files or not notices:
        raise ValueError("Engine and distribution notices must be pinned")
    for name in notices:
        if name not in files or name == "ffmpeg.exe":
            raise ValueError("Every notice must be a separately pinned file")
    for name, expected in files.items():
        target = (directory / name).resolve()
        if not target.is_relative_to(directory) or not target.is_file():
            raise ValueError(f"Missing or unsafe payload: {name}")
        with target.open("rb") as payload:
            actual = hashlib.file_digest(payload, "sha256").hexdigest()
        if actual.lower() != str(expected).lower():
            raise ValueError(f"SHA256 mismatch: {name}")
    return manifest


def stage(source, destination):
    """Copy only reviewed manifest entries, validating before publishing a folder."""
    source, destination = Path(source).resolve(), Path(destination).resolve()
    if destination.exists():
        raise ValueError("Destination already exists; verify it or choose a fresh staging path")
    manifest = verify(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ffmpeg-stage-", dir=destination.parent) as temporary:
        scratch = Path(temporary) / "ffmpeg"
        scratch.mkdir()
        for name in ["distribution.json", *manifest["files"]]:
            target = scratch / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / name, target)
        verify(scratch)
        scratch.rename(destination)


def main():
    """Expose explicit stage and package-verification operations for build scripts."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--stage", type=Path, help="Fresh destination; otherwise verify source only")
    args = parser.parse_args()
    if args.stage:
        stage(args.source, args.stage)
    result = verify(args.stage or args.source)
    print(json.dumps({"status": "verified", "version": result["version"], "files": len(result["files"])}))


if __name__ == "__main__":
    main()
