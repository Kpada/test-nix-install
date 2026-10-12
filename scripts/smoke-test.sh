#!/usr/bin/env bash
# Shared installation and offline-build checks for both installers.
set -euo pipefail

# Verify Nix version $1, environment propagation and store integrity.
check_installation()
{
    command -v nix
    nix --version
    test "$(nix eval --raw --expr builtins.nixVersion)" = "$1"
    test "$(nix eval --impure --raw --expr builtins.currentSystem)" = x86_64-linux
    test "${NIX_REMOTE:-local}" = local
    test -f "$NIX_SSL_CERT_FILE"
    nix-store --verify --check-contents
}

# Build a local derivation without substitutes and verify its output.
check_build()
{
    local result
    result="$(nix-build --no-out-link --option substituters '' --expr '
        derivation {
            name = "nix-install-smoke";
            system = builtins.currentSystem;
            builder = "/bin/sh";
            args = [ "-c" "echo verified > $out" ];
        }')"
    test "$(cat "$result")" = verified
}

# Run checks for version $1 and report success to stdout and the Actions summary.
main()
{
    (( $# == 1 )) || { echo "Usage: $0 VERSION" >&2; exit 1; }
    check_installation "$1"
    check_build
    printf 'Nix %s: installation, environment, store and offline build passed.\n' "$1" \
        | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

main "$@"
