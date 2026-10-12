# Quick Nix for Ubuntu

Prepare a small archive of **official Nix binaries**, then install it on a fresh
GitHub-hosted Ubuntu x86-64 runner. Installation streams the archive through
`curl | tar`, imports the store registration and creates the user profile.
No daemon, channels or NIX_PATH setup. `nix-command` and flakes are enabled.

- Root action and `prepare.sh`: prepare the archive once.
- `install/action.yml` and `install.sh`: install the prepared archive.
- `scripts/minimal_closure.py`: keep Nix and its runtime dependencies.
- `scripts/smoke-test.sh`: verify the installation and an offline build.

## How it works

Packaging downloads an official `.tar.xz` release, reads its `.reginfo` records,
and keeps the Nix package and all store paths it references, transitively.
It writes their registration and a pointer to Nix, then creates a tar archive
with normalized metadata and compresses it with zstd. No Nix compilation is needed.

Installation downloads and unpacks the `.tar.zst` directly into `/nix` in one
stream. It imports the registration with `nix-store --load-db`, creates the user
profile with `nix-env`, and exports PATH and Nix variables for subsequent steps.

The consumer job only extracts ready binaries and sets up the store and profile;
packaging happens once. Fast zstd decompression overlaps with downloading.
Compared with the usual [daemon installation](https://releases.nixos.org/nix/nix-2.34.7/manual/installation/installing-binary.html),
we also skip build-user groups and service setup. Installation time still depends
on network and runner performance.

## Prepare a release

Run **Prepare minimal Nix archives** in Actions:

- `nix_versions`: `2.34.7 2.33.6` (spaces or commas; one version also works)
- `release_tag`: `nix-binaries-r1` (any new tag, independent of Nix versions)

The workflow packages every requested version and publishes all archives in a
single release. Each version has one asset, for example:

```text
nix-2.34.7-x86_64-linux.tar.zst
nix-2.33.6-x86_64-linux.tar.zst
```

Only x86-64 Linux binaries are packaged. No manifests or checksum files are
generated. Publication happens after all versions have been packaged successfully.
Use a new tag if the release already exists. Keep the archives public so consumer
jobs can download them directly.

## Use in another repository

Replace `FULL_COMMIT_SHA` with a commit containing the installer, and choose
the release tag and version in the archive URL:

```yaml
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: Kpada/test-nix-install/install@FULL_COMMIT_SHA
        with:
          archive-url: https://github.com/Kpada/test-nix-install/releases/download/nix-binaries-r1/nix-2.34.7-x86_64-linux.tar.zst
      - run: nix --version
```

The installer requires an absent or empty, writable `/nix`. PATH and Nix
environment variables persist to subsequent Actions steps. Add settings with
`nix-conf`; the installer writes the user's `nix.conf` and uses Ubuntu's CA bundle.

## Compare installation speed

**Test Nix installation** runs on push and manually. It compares our installer
with nixbuild v35 on separate Ubuntu x86-64 runners, using the same Nix version
and smoke test. Both download existing archives; packaging is outside the test.

Defaults are Nix `2.34.7` and release `nix-2.34.7-r1`. Manual inputs select another
version and release; use `nix-binaries-r1` to compare an archive from the example
release above. Download and installation time appears in milliseconds in
the logs and Actions summary. The timer includes transitions between Actions
steps; checkout and smoke tests are outside the measurement.

## Run scripts directly

```bash
bash prepare.sh 2.34.7 nix-archives
NIX_CONF='sandbox = false' bash install.sh nix-archives/nix-2.34.7-x86_64-linux.tar.zst
. "$HOME/.nix-profile/etc/profile.d/nix.sh"
export NIX_REMOTE=local NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
bash scripts/smoke-test.sh 2.34.7
```

The smoke test uses the runner's `/bin/sh`, so this example disables the sandbox.

Packaging requires Bash, curl, GNU tar, xz, zstd and Python 3. Installation
requires Bash, curl, GNU tar and unzstd. Standard Ubuntu Actions runners provide
them. Archives contain `nix/store` plus `nix/var/quick-nix/{nix,registration,platform}`.
