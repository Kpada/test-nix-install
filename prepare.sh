#!/usr/bin/env bash
# Package official Nix binaries for x86-64 Linux.
set -euo pipefail
umask 022

# Kept global for the EXIT cleanup trap.
work_dir=""

# Print command usage and the default output directory.
usage()
{
    printf 'Usage: %s VERSION [OUTPUT_DIRECTORY]\n\n' "${0##*/}"
    printf 'Prepare a Nix archive. OUTPUT_DIRECTORY defaults to nix-archives.\n'
}

# Print the supplied error message to stderr and exit with status 1.
fail()
{
    printf '%s\n' "$*" >&2
    exit 1
}

# Restore write permissions and remove the temporary staging directory.
cleanup()
{
    chmod -R u+w "$work_dir"
    rm -rf -- "$work_dir"
}

# Download official Nix version $1 and unpack it in staging directory $2.
download_source()
{
    local version="$1"
    local destination="$2"
    local url="https://releases.nixos.org/nix/nix-$version/nix-$version-x86_64-linux.tar.xz"

    curl --silent --show-error --fail --location --retry 3 --connect-timeout 20 \
        "$url" --output "$destination/source.tar.xz"
    mkdir "$destination/unpack"
    tar --extract --xz --no-same-owner --file "$destination/source.tar.xz" \
        --directory "$destination/unpack"
}

# Pack the staging tree at $1 into the normalized zstd archive at $2.
pack_archive()
{
    local source="$1"
    local archive="$2"

    tar --sort=name --format=gnu --mtime=@0 --owner=0 --group=0 --numeric-owner \
        --hard-dereference --create --file=- --directory="$source" nix \
        | zstd --quiet -T1 -3 --force -o "$archive"
}

# Handle CLI arguments, stage the runtime closure and write the archive.
main()
{
    case "${1:-}" in
        -h|--help) usage; return 0 ;;
    esac
    if (( $# < 1 || $# > 2 )); then
        usage >&2
        return 2
    fi
    local version="$1"
    local output_dir="${2:-nix-archives}"
    local command script_dir archive

    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Expected an exact release version"
    for command in curl tar xz zstd python3; do
        command -v "$command" >/dev/null || fail "Missing command: $command"
    done

    mkdir -p "$output_dir"
    output_dir="$(cd "$output_dir" && pwd)"
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    work_dir="$(mktemp -d)"
    trap cleanup EXIT

    download_source "$version" "$work_dir"
    python3 "$script_dir/scripts/minimal_closure.py" \
        "$work_dir/unpack/nix-$version-x86_64-linux" "$work_dir/root" "$version"
    archive="$output_dir/nix-$version-x86_64-linux.tar.zst"
    pack_archive "$work_dir/root" "$archive"

    printf 'Archive: %s\n' "$archive"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf 'archive=%s\n' "$archive" >> "$GITHUB_OUTPUT"
    fi
}

main "$@"
