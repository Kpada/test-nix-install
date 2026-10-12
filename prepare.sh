#!/usr/bin/env bash
set -euo pipefail
umask 022

# Usage: prepare.sh VERSION PLATFORM SOURCE_SHA256 OUTPUT_DIR [LOCAL_TAR_XZ]
if (( $# < 4 || $# > 5 )); then
  echo "Usage: $0 VERSION PLATFORM SOURCE_SHA256 OUTPUT_DIR [LOCAL_TAR_XZ]" >&2
  exit 2
fi
version="$1"
platform="$2"
source_sha="${3,,}"
output_dir="$4"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected an exact release version" >&2; exit 2; }
[[ "$source_sha" =~ ^[0-9a-f]{64}$ ]] || { echo "Expected a pinned SHA256" >&2; exit 2; }
case "$platform" in x86_64-linux|aarch64-linux) ;; *) echo "Unsupported platform: $platform" >&2; exit 2 ;; esac
for command in curl tar xz zstd python3 sha256sum; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
cleanup() {
  chmod -R u+w "$work"
  python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1])' "$work"
}
trap cleanup EXIT
source_url="https://releases.nixos.org/nix/nix-$version/nix-$version-$platform.tar.xz"
source_archive="$work/source.tar.xz"
if (( $# == 5 )); then
  cp -- "$5" "$source_archive"
else
  curl --fail --location --retry 3 --connect-timeout 20 \
    "$source_url" --output "$source_archive"
fi
printf '%s  %s\n' "$source_sha" "$source_archive" | sha256sum --check --status
mkdir "$work/unpack"
tar --extract --xz --no-same-owner --file "$source_archive" --directory "$work/unpack"
python3 "$script_dir/scripts/minimal_closure.py" \
  "$work/unpack/nix-$version-$platform" "$work/root" "$version" "$platform"
archive="$output_dir/nix-$version-$platform.tar.zst"
# Canonical tar metadata and single-threaded zstd. Pin tool versions too if
# byte-for-byte reproduction across different packaging hosts is required.
tar --sort=name --format=gnu --mtime=@0 --owner=0 --group=0 --numeric-owner \
  --hard-dereference --create --file=- --directory="$work/root" nix \
  | zstd --quiet -T1 -3 --force -o "$work/archive.tar.zst"
mv -- "$work/archive.tar.zst" "$archive"
archive_sha="$(sha256sum "$archive" | cut -d ' ' -f 1)"
manifest="$archive.json"
python3 - "$manifest" "$version" "$platform" "$source_url" "$source_sha" "$archive" "$archive_sha" "$work/root/nix/var/quick-nix" <<'PY'
import json, sys
from pathlib import Path
out, version, platform, url, source_sha, archive, archive_sha, metadata = sys.argv[1:]
data = {
    "format": 1, "nix_version": version, "platform": platform,
    "source_url": url, "source_sha256": source_sha,
    "archive": Path(archive).name, "sha256": archive_sha,
    "nix_store_path": str((Path(metadata) / "nix").readlink()),
    "store_paths": int((Path(metadata) / "store-path-count").read_text()),
}
Path(out).write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
printf 'Archive: %s\nSHA256: %s\nManifest: %s\n' "$archive" "$archive_sha" "$manifest"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'archive=%s\nsha256=%s\nmanifest=%s\n' "$archive" "$archive_sha" "$manifest" >> "$GITHUB_OUTPUT"
fi

