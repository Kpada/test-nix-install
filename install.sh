#!/usr/bin/env bash
# Install a prepared Nix archive on a fresh x86-64 Ubuntu runner.
set -euo pipefail
umask 022

# Print command usage and the supported configuration variable.
usage()
{
    printf 'Usage: %s HTTPS_URL_OR_LOCAL_ARCHIVE\n\n' "${0##*/}"
    printf 'Install Nix from a public HTTPS URL or a local archive.\n'
    printf 'NIX_CONF appends settings to the user configuration.\n'
}

# Print the supplied error message to stderr and exit with status 1.
fail()
{
    printf '%s\n' "$*" >&2
    exit 1
}

# Create a single-user store; refuse to overwrite an existing installation.
prepare_store()
{
    if [[ -e /nix || -L /nix ]]; then
        [[ -d /nix && ! -L /nix && -w /nix && -z "$(ls -A /nix)" ]] \
            || fail "Expected /nix to be absent or empty and writable"
    elif (( EUID == 0 )); then
        install -d -m 0755 /nix
    else
        sudo install -d -m 0755 -o "$(id -un)" -g "$(id -gn)" /nix
    fi
}

# Stream the archive at $1 (HTTPS URL or local file) to stdout.
read_archive()
{
    case "$1" in
        https://*)
            curl --silent --show-error --fail --location --retry 3 \
                --connect-timeout 20 "$1"
            ;;
        *://*)
            fail "Expected an HTTPS URL or a local file"
            ;;
        *)
            cat -- "$1"
            ;;
    esac
}

# Stream and extract the archive at $1 directly into /nix.
extract_archive()
{
    read_archive "$1" | tar --extract --file=- --use-compress-program=unzstd \
        --no-same-owner --delay-directory-restore --strip-components=1 --directory /nix
}

# Validate the archive platform and the Nix store path supplied in $1.
validate_archive()
{
    [[ "$(cat /nix/var/quick-nix/platform)" == x86_64-linux ]] \
        || fail "Archive platform does not match this runner"
    [[ "$1" =~ ^/nix/store/[0-9a-z]{32}-nix-[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || fail "Invalid Nix path in archive"
}

# Configure a local store, Ubuntu's CA bundle and optional NIX_CONF settings.
configure_nix()
{
    local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/nix"

    export USER="${USER:-$(id -un)}"
    export NIX_REMOTE=local
    export NIX_SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
    [[ -f "$NIX_SSL_CERT_FILE" ]] || fail "Missing system CA certificate bundle"

    mkdir -p "$config_dir"
    cat > "$config_dir/nix.conf" <<'CONF'
build-users-group =
extra-experimental-features = nix-command flakes
accept-flake-config = true
CONF
    printf '\n%s\n' "${NIX_CONF:-}" >> "$config_dir/nix.conf"
}

# Register the extracted store and install the Nix package at $1 in the profile.
install_profile()
{
    local nix_root="$1"

    "$nix_root/bin/nix-store" --load-db < /nix/var/quick-nix/registration
    # nix.sh expects MANPATH even when the shell runs with nounset.
    MANPATH= . "$nix_root/etc/profile.d/nix.sh"
    "$nix_root/bin/nix-env" -i "$nix_root"
}

# Make Nix available in subsequent Actions steps.
export_actions_environment()
{
    if [[ -n "${GITHUB_PATH:-}" ]]; then
        printf '%s\n' "$HOME/.nix-profile/bin" >> "$GITHUB_PATH"
    fi
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        printf 'NIX_REMOTE=local\nNIX_PROFILES=%s\nNIX_USER_PROFILE_DIR=%s\nNIX_SSL_CERT_FILE=%s\n' \
            "/nix/var/nix/profiles/default $HOME/.nix-profile" \
            "/nix/var/nix/profiles/per-user/$USER" "$NIX_SSL_CERT_FILE" >> "$GITHUB_ENV"
    fi
}

# Handle CLI arguments and run the installation steps in order.
main()
{
    case "${1:-}" in
        -h|--help) usage; return 0 ;;
    esac
    if (( $# != 1 )); then
        usage >&2
        return 2
    fi
    [[ "$(uname -sm)" == "Linux x86_64" ]] || fail "Only x86-64 Linux is supported"
    local command nix_root
    for command in curl tar unzstd; do
        command -v "$command" >/dev/null || fail "Missing command: $command"
    done

    prepare_store
    extract_archive "$1"
    nix_root="$(readlink /nix/var/quick-nix/nix)"
    validate_archive "$nix_root"

    configure_nix
    install_profile "$nix_root"
    export_actions_environment
    "$HOME/.nix-profile/bin/nix" --version
}

main "$@"
