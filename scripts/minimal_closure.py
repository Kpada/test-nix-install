#!/usr/bin/env python3
"""Stage Nix and its runtime dependencies from an unpacked official release."""

import argparse
import re
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

STORE_PATH = re.compile(r"/nix/store/[0-9a-z]{32}-[^/\s]+")
REGISTRATION_HEADER_SIZE = 5


@dataclass
class StoreEntry:
    """Registration data for one store path.

    Attributes:
        references: Absolute store paths referenced by this entry.
        lines: Original .reginfo record, including its header and references.
    """

    references: list[str]
    lines: list[str]


def parse_args() -> argparse.Namespace:
    """Parse the command-line arguments.

    Returns:
        Arguments with source, destination and version fields.

    Raises:
        SystemExit: Help was requested or the command-line arguments are invalid.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Unpacked official Nix release directory")
    parser.add_argument("destination", type=Path, help="Directory in which to stage nix/")
    parser.add_argument("version", help="Exact Nix release version, for example 2.34.7")
    return parser.parse_args()


def find_nix_root(source: Path, version: str) -> str:
    """Read the requested Nix store path from the upstream installer.

    Args:
        source: Unpacked official release directory containing the install script.
        version: Exact Nix version expected in the package's store path.

    Returns:
        Absolute store path of the Nix package.

    Raises:
        OSError: The upstream install script cannot be read.
        ValueError: The Nix path is missing, malformed or has a different version.
    """
    installer = (source / "install").read_text()
    match = re.search(
        r'^nix=["\'](/nix/store/[^"\'\n]+)["\']$', installer, re.MULTILINE
    )
    if (
        not match
        or not STORE_PATH.fullmatch(match[1])
        or not match[1].endswith("-nix-" + version)
    ):
        raise ValueError("Cannot find the requested Nix version in the official installer")
    return match[1]


def read_registration(path: Path) -> dict[str, StoreEntry]:
    """Read .reginfo records while preserving their serialized form.

    Args:
        path: Upstream .reginfo file to read.

    Returns:
        Registration entries keyed by absolute store path.

    Raises:
        OSError: The registration file cannot be read.
        ValueError: A record is truncated, duplicated or contains invalid paths
            or reference counts.
    """
    lines = path.read_text().splitlines()
    records: dict[str, StoreEntry] = {}
    offset = 0

    while offset < len(lines):
        start = offset
        # Header: path, NAR hash, size, deriver, reference count.
        header = lines[offset:offset + REGISTRATION_HEADER_SIZE]
        if len(header) != REGISTRATION_HEADER_SIZE:
            raise ValueError("Truncated registration header")
        store_path = header[0]
        count = int(header[4])
        if not STORE_PATH.fullmatch(store_path) or store_path in records or count < 0:
            raise ValueError(f"Invalid registration: {store_path}")
        offset += REGISTRATION_HEADER_SIZE
        references = lines[offset:offset + count]
        if len(references) != count or any(
            not STORE_PATH.fullmatch(ref) for ref in references
        ):
            raise ValueError(f"Invalid references: {store_path}")
        offset += count
        records[store_path] = StoreEntry(references, lines[start:offset])

    return records


def collect_paths(root: str, records: dict[str, StoreEntry]) -> list[str]:
    """Collect the Nix package and all of its transitive dependencies.

    Args:
        root: Absolute store path of the Nix package.
        records: Available registration entries keyed by absolute store path.

    Returns:
        Sorted store paths forming the runtime closure, including root.

    Raises:
        ValueError: The root or a required dependency is missing from records.
    """
    keep: set[str] = set()
    pending = [root]

    while pending:
        path = pending.pop()
        if path in keep:
            continue
        if path not in records:
            raise ValueError(f"Missing dependency: {path}")
        keep.add(path)
        pending.extend(records[path].references)

    return sorted(keep)


def make_store_read_only(store: Path) -> None:
    """Make store entries read-only, preserving executability and symlinks.

    Args:
        store: Staged nix/store directory whose entries will be updated.

    Raises:
        OSError: An entry cannot be inspected or its permissions cannot be changed.
    """
    for entry in store.rglob("*"):
        if not entry.is_symlink():
            entry.chmod(entry.stat().st_mode & 0o777 & ~0o222)


def stage_archive(
    source: Path,
    destination: Path,
    root: str,
    paths: list[str],
    records: dict[str, StoreEntry],
) -> None:
    """Move selected store paths into the archive tree and write installer metadata.

    Args:
        source: Unpacked release directory; selected entries are moved from store/.
        destination: Staging directory in which the nix/ subtree will be created.
        root: Absolute Nix store path used as the installer's symlink target.
        paths: Store paths to move into the archive, in the desired record order.
        records: Registration entries for the selected store paths.

    Raises:
        OSError: Store paths cannot be moved or staging files cannot be written.
        KeyError: A selected store path has no registration entry.
    """
    store = destination / "nix/store"
    metadata = destination / "nix/var/quick-nix"
    store.mkdir(parents=True)
    metadata.mkdir(parents=True)

    for path in paths:
        name = Path(path).name
        shutil.move(str(source / "store" / name), store / name)
    make_store_read_only(store)

    registration = "\n".join(line for path in paths for line in records[path].lines)
    (metadata / "registration").write_text(registration + "\n")
    (metadata / "nix").symlink_to(root)
    (metadata / "platform").write_text("x86_64-linux\n")


def main() -> int:
    """Stage the runtime closure and report failures without a traceback.

    Returns:
        Exit status: zero on success, one on a processing or filesystem error.

    Raises:
        SystemExit: Argument parsing handles help or invalid command-line arguments.
    """
    args = parse_args()
    try:
        root = find_nix_root(args.source, args.version)
        records = read_registration(args.source / ".reginfo")
        paths = collect_paths(root, records)
        stage_archive(args.source, args.destination, root, paths, records)
    except (ValueError, OSError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    print(f"Keeping {len(paths)} of {len(records)} store paths")
    return 0


if __name__ == "__main__":
    sys.exit(main())
