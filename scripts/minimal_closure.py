#!/usr/bin/env python3
"""Select the transitive Nix closure from a verified official release tarball."""
import re
import shutil
import sys
from pathlib import Path

STORE_PATH = re.compile(r"/nix/store/[0-9a-z]{32}-[^/\s]+")


def select_closure(source: Path, destination: Path, version: str, platform: str) -> None:
    installer = (source / "install").read_text()
    match = re.search(r'^nix=["\'](/nix/store/[^"\'\n]+)["\']$', installer, re.MULTILINE)
    if not match or not STORE_PATH.fullmatch(match[1]):
        raise ValueError("Cannot find the Nix root in the official installer")
    root = match[1]
    if not root.endswith("-nix-" + version):
        raise ValueError("Installer version does not match the requested version")

    # nix-store --load-db format:
    # path, NAR hash, NAR size, deriver, reference count, references...
    lines = (source / ".reginfo").read_text().splitlines()
    records = {}
    cursor = 0
    while cursor < len(lines):
        start = cursor
        path, nar_hash, nar_size, deriver, count = lines[cursor:cursor + 5]
        if not STORE_PATH.fullmatch(path) or path in records:
            raise ValueError(f"Invalid or duplicate store path: {path}")
        if not nar_hash.startswith("sha256:") or int(nar_size) < 0:
            raise ValueError(f"Invalid NAR metadata for {path}")
        count = int(count)
        if count < 0:
            raise ValueError("Negative reference count")
        cursor += 5
        refs = lines[cursor:cursor + count]
        if len(refs) != count or any(not STORE_PATH.fullmatch(ref) for ref in refs):
            raise ValueError(f"Invalid references for {path}")
        cursor += count
        records[path] = (refs, lines[start:cursor])

    keep = set()
    pending = [root]
    while pending:
        path = pending.pop()
        if path in keep:
            continue
        if path not in records:
            raise ValueError(f"Dependency missing from registration: {path}")
        keep.add(path)
        pending.extend(records[path][0])

    store = destination / "nix/store"
    metadata = destination / "nix/var/quick-nix"
    store.mkdir(parents=True)
    metadata.mkdir(parents=True)
    for path in sorted(keep):
        src = source / "store" / Path(path).name
        if not src.exists() and not src.is_symlink():
            raise ValueError(f"Dependency missing from archive: {path}")
        shutil.move(str(src), store / src.name)
    # Match a normally installed store: directories/files are read-only.
    # Preserve executable bits and never follow store symlinks.
    for entry in store.rglob("*"):
        if not entry.is_symlink():
            entry.chmod(entry.stat().st_mode & 0o777 & ~0o222)
    registration = "\n".join(
        line for path in sorted(keep) for line in records[path][1]
    ) + "\n"
    (metadata / "registration").write_text(registration)
    (metadata / "nix").symlink_to(root)
    (metadata / "version").write_text(version + "\n")
    (metadata / "platform").write_text(platform + "\n")
    (metadata / "store-path-count").write_text(str(len(keep)) + "\n")
    print(f"Keeping {len(keep)} of {len(records)} store paths (Nix runtime closure)")


if __name__ == "__main__":
    try:
        select_closure(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4])
    except (ValueError, OSError, IndexError) as error:
        sys.exit(str(error))

