#!/usr/bin/env bash
# Shared release and asset naming for the Nix actions.

# Bump before preparing new archives and publishing a new installer version.
NIX_ARCHIVE_RELEASE="nix-install-archives-v1"

# Validate the exact Nix version in $1 and print its asset name.
nix_archive_name()
{
    local version="$1"

    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf 'Expected an exact Nix release version (X.Y.Z)\n' >&2
        return 1
    fi
    printf 'nix-%s-x86_64-linux.tar.zst\n' "$version"
}
