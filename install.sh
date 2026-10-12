#!/usr/bin/env bash
set -euo pipefail
umask 022

# Usage: install.sh HTTPS_URL_OR_LOCAL_ARCHIVE [PINNED_SHA256]
# Intended for a fresh Linux GitHub-hosted runner.
if (( $# < 1 || $# > 2 )); then
  echo "Usage: $0 HTTPS_URL_OR_LOCAL_ARCHIVE [PINNED_SHA256]" >&2
  exit 2
fi
source_archive="$1"
expected_sha="${2:-}"
if [[ -n "$expected_sha" ]]; then
  expected_sha="${expected_sha,,}"
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || { echo "Expected a pinned SHA256" >&2; exit 2; }
fi
[[ "$(uname -s)" == Linux ]] || { echo "Only Linux runners are supported" >&2; exit 1; }
case "$(uname -m)" in
  x86_64) platform=x86_64-linux ;;
  aarch64) platform=aarch64-linux ;;
  *) echo "Unsupported architecture" >&2; exit 1 ;;
esac
for command in curl tar unzstd sha256sum; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
if [[ -e /nix || -L /nix ]]; then
  [[ -d /nix && ! -L /nix && -w /nix && -z "$(ls -A /nix)" ]] || {
    echo "Expected /nix to be absent or empty and writable; existing installations are unsupported" >&2
    exit 1
  }
fi
download_archive() {
  case "$source_archive" in
    https://*)
      if [[ -n "${GH_TOKEN:-}" && "$source_archive" =~ ^https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/([^/]+)$ ]]; then
        gh release download "${BASH_REMATCH[2]}" --repo "${BASH_REMATCH[1]}" \
          --pattern "${BASH_REMATCH[3]}" --output -
      else
        curl --silent --show-error --fail --location --retry 3 --connect-timeout 20 \
          "$source_archive"
      fi
      ;;
    *://*) echo "Expected an HTTPS URL or a local file" >&2; return 2 ;;
    *) cat -- "$source_archive" ;;
  esac
}
extract_archive() {
  tar --extract --use-compress-program=unzstd --no-same-owner --delay-directory-restore \
    --strip-components=1 --file "$1" --directory /nix
}

if [[ -n "$expected_sha" ]]; then
  work="$(mktemp -d)"
  trap 'rm -rf -- "$work"' EXIT
  archive="$work/nix.tar.zst"
  download_archive > "$archive"
  printf '%s  %s\n' "$expected_sha" "$archive" | sha256sum --check --status
fi

if [[ ! -d /nix ]]; then
  if (( EUID == 0 )); then
    install -d -m 0755 /nix
  else
    sudo install -d -m 0755 -o "$(id -un)" -g "$(id -gn)" /nix
  fi
fi
if [[ -n "$expected_sha" ]]; then
  extract_archive "$archive"
else
  download_archive | extract_archive -
fi
metadata=/nix/var/quick-nix
[[ "$(cat "$metadata/platform")" == "$platform" ]] || {
  echo "Archive platform does not match this runner" >&2; exit 1;
}
nix_root="$(readlink "$metadata/nix")"
[[ "$nix_root" =~ ^/nix/store/[0-9a-z]{32}-nix-[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Invalid Nix root in archive" >&2; exit 1;
}

export USER="${USER:-$(id -un)}"
export NIX_REMOTE=local
if [[ -z "${NIX_SSL_CERT_FILE:-}" ]]; then
  for certificate in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do
    if [[ -f "$certificate" ]]; then
      export NIX_SSL_CERT_FILE="$certificate"
      break
    fi
  done
fi
[[ -f "${NIX_SSL_CERT_FILE:-}" ]] || { echo "No system CA certificate bundle found" >&2; exit 1; }
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/nix"
mkdir -p "$config_dir"
cat > "$config_dir/nix.conf" <<'CONF'
build-users-group =
extra-experimental-features = nix-command flakes
accept-flake-config = true
CONF
if [[ -n "${NIX_CONF:-}" ]]; then
  printf '\n%s\n' "$NIX_CONF" >> "$config_dir/nix.conf"
fi
"$nix_root/bin/nix-store" --load-db < "$metadata/registration"
MANPATH= . "$nix_root/etc/profile.d/nix.sh"
"$nix_root/bin/nix-env" -i "$nix_root"
if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$HOME/.nix-profile/bin" >> "$GITHUB_PATH"
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'NIX_REMOTE=local\nNIX_PROFILES=%s\nNIX_USER_PROFILE_DIR=%s\nNIX_SSL_CERT_FILE=%s\n' \
    "/nix/var/nix/profiles/default $HOME/.nix-profile" \
    "/nix/var/nix/profiles/per-user/$USER" "$NIX_SSL_CERT_FILE" >> "$GITHUB_ENV"
fi
"$HOME/.nix-profile/bin/nix" --version
echo "Nix installed. Outside Actions, source $nix_root/etc/profile.d/nix.sh before use."

