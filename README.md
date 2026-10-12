# Quick Nix for Ubuntu

Prepare a small archive of **official Nix binaries**, then install it on a fresh
GitHub-hosted Ubuntu x86-64 runner. Installation streams the archive through
`curl | tar`, imports the store registration and creates the user profile.
No daemon, channels or NIX_PATH setup. `nix-command` and flakes are enabled.

- Root action and `prepare.sh`: prepare the archive once.
- `install/action.yml` and `install.sh`: install the prepared archive.
- `scripts/archive.sh`: shared asset names and the pinned archive release tag.
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

The workflow uses the release tag pinned in `scripts/archive.sh`, currently
`nix-install-archives-v1`. It packages every requested version and publishes all
archives in that release. Each version has one asset, for example:

```text
nix-2.34.7-x86_64-linux.tar.zst
nix-2.33.6-x86_64-linux.tar.zst
```

Only x86-64 Linux binaries are packaged. No manifests or checksum files are
generated. Publication happens after all versions have been packaged successfully.
Existing releases and tags are rejected. Archive tags use the
`nix-install-archives-vN` prefix, and publication uses `--latest=false` so other
actions in the repository can have their own releases and Latest designation.
Keep the archives public so consumer jobs can download them directly.

For a new archive release, bump `NIX_ARCHIVE_RELEASE` in `scripts/archive.sh`,
publish all supported Nix versions with this workflow, then publish a new installer
version or pin its commit. Installer tags can use a separate `nix-install-vN`
prefix. Each installer version stays tied to its archive release.

The packaging action returns `archive` (absolute path), `archive-name` (asset
name), and `release-tag`. Packaging and installation share the same naming rule.

## Use in another repository

Replace `FULL_COMMIT_SHA` with a commit whose pinned archive release has been
published. Choose only the Nix version:

```yaml
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: Kpada/test-nix-install/install@FULL_COMMIT_SHA
        with:
          nix-version: "2.34.7"
      - run: nix --version
```

The installer constructs the download URL from its own repository, the pinned
release tag, and the version's asset name. It makes no API requests to search
releases. The requested version must be included in that pinned release.

The installer requires an absent or empty, writable `/nix`. PATH and Nix
environment variables persist to subsequent Actions steps. Add settings with
`nix-conf`; the installer writes the user's `nix.conf` and uses Ubuntu's CA bundle.

## Compare installation speed

**Test Nix installation** runs on push and manually. It compares our installer
with nixbuild v35 on separate Ubuntu x86-64 runners, using the same Nix version
and smoke test. Both download existing archives; packaging is outside the test.

The default is Nix `2.34.7`; the manual input selects another version included in
the pinned archive release. Publish that release before running the comparison.
Download and installation time appears in milliseconds in
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
