# Minimal Nix packaging and installation

Small, Linux-only GitHub Actions kit. It repacks **official Nix binaries** into a
minimal zstd archive. It does not download binaries produced by nixbuild and
does not compile Nix from source.

- Root action: package one exact Nix version/platform.
- `install/action.yml`: install one checksum-pinned archive.
- `install.sh`: the same installer, usable directly.
- `.github/workflows/prepare.yml`: manually package and publish both Linux architectures.
- `.github/workflows/test.yml`: manually smoke-test installation on both Linux architectures.
- `sources.json`: reviewed upstream checksums (initial version: 2.34.7).

Supported installation target: a **fresh GitHub-hosted Linux runner**, x86_64 or
aarch64. Single-user installation, no daemon, channels, NIX_PATH or shell-profile
edits. Uses the runner's system CA bundle. Requires Bash, GNU tar, zstd/unzstd,
curl, xz and Python 3 for packaging; installation does not need Python.
Standard Ubuntu runners provide these tools.

## Test the installer manually

In Actions, select **Test Nix installation**, click **Run workflow**, and keep
`nix_version` set to `2.34.7` (or choose another version pinned in `sources.json`).
The workflow runs on `ubuntu-24.04` (x86_64) and `ubuntu-24.04-arm` (aarch64).
It prepares a local archive with the root action, then installs it using
`./install` from the selected workflow ref. No archive release is needed.

Subsequent steps check the exact Nix version and platform, PATH and environment
propagation, store integrity, expression evaluation, and an offline derivation.
The test also passes `sandbox = false` through the installer's `nix-conf` input
so the derivation can use the runner's `/bin/sh`. Each job writes its results
to the Actions summary.

Commit the workflow to the repository's default branch first so GitHub enables
the [manual trigger](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onworkflow_dispatch).

## 1. Create your archive release

Put these files in your GitHub repository and commit them. In Actions, run
**Prepare minimal Nix archives** with the default values:

- Nix version: `2.34.7`
- Release tag: `nix-2.34.7-r1`

The workflow downloads and verifies the official archives, follows the
transitive references in `.reginfo` starting from the Nix package, and discards
store paths outside that closure. It does not execute the upstream installer.
It packages both architectures, tests x86_64 installation and an offline build,
then creates a release with archives, JSON manifests and SHA256SUMS.

For Nix 2.34.7 x86_64, 61 of 63 store paths are retained: the separate
`nss-cacert` and manual-page outputs are excluded.

To add a version, add its official tarball SHA256 values to `sources.json` and
commit the change before dispatching. The versioned official `install` script
lists these hashes:
https://releases.nixos.org/nix/nix-2.34.7/install
Review and pin them; they are not fetched or trusted automatically at runtime.

Archive generation happens once for each version/platform, not in consumer jobs.
An existing release must not be replaced; use a new revision tag.

## 2. Install in another repository

Replace the repository, commit and archive hash below with your own values.
The SHA256 is in the corresponding archive's JSON manifest.

```yaml
steps:
  - uses: YOUR-OWNER/YOUR-REPO/install@FULL_COMMIT_SHA
    with:
      archive-url: https://github.com/YOUR-OWNER/YOUR-REPO/releases/download/nix-2.34.7-r1/nix-2.34.7-x86_64-linux.tar.zst
      archive-sha256: YOUR_PINNED_64_HEX_SHA256
  - run: nix --version
  - run: nix build
```

Use the `aarch64-linux` archive on an ARM runner.
The installer verifies the archive before modifying `/nix`, extracts straight
into `/nix`, imports the store registration with `nix-store --load-db` and
installs Nix in the user profile. PATH and Nix environment variables persist to
subsequent Actions steps through GITHUB_PATH/GITHUB_ENV.

Default user configuration:

```ini
build-users-group =
extra-experimental-features = nix-command flakes
accept-flake-config = true
```

Add settings with the optional `nix-conf` input. The installer writes the user
`nix.conf`; use it on fresh runners only. It rejects a nonempty `/nix`.

## Direct scripts

Package an archive on any Linux host; packaging aarch64 does not execute ARM code:

```bash
bash prepare.sh 2.34.7 x86_64-linux \
  eafe5042404e818505e28c5ca3d0885f3ec45c31f955489a25bb38258f87560e \
  nix-archives
```

Optional fifth argument: an already downloaded official tar.xz. Its pinned
checksum is still verified.

Install a local archive or an HTTPS URL:

```bash
bash install.sh /path/to/nix-2.34.7-x86_64-linux.tar.zst PINNED_SHA256
. "$HOME/.nix-profile/etc/profile.d/nix.sh"
export NIX_REMOTE=local
nix --version
```

Outside Actions, the script's exports cannot change the parent shell. Source
`nix.sh` as above before use.

## Determinism and archive layout

Pin the action commit, Nix version, official source checksum and your published
archive checksum. Replacing a release asset with different bytes fails verification.

Tar ordering, timestamps and ownership are normalized; zstd uses one thread and
an explicit compression level. Byte-identical regeneration across different
hosts also requires identical GNU tar and zstd versions. The published archive
hash, once pinned, fixes the actual bytes consumed by installation.

```text
nix/store/<Nix package and transitive dependencies>
nix/var/quick-nix/registration
nix/var/quick-nix/nix -> /nix/store/<Nix package>
nix/var/quick-nix/version
nix/var/quick-nix/platform
nix/var/quick-nix/store-path-count
```

No prebuilt SQLite database is shipped. Each runner imports the registration.
Installation is designed like nixbuild/nix-quick-install-action: a prepared
runtime closure, zstd, direct extraction, no daemon or channels. The actual
installation time depends on download latency and runner performance.

## Verification

See `VERIFICATION.md` for checks actually performed when this kit was created.
The release workflow additionally tests x86_64 on a real Ubuntu Actions runner.
It explicitly labels aarch64 as packaged but not execution-tested.

This kit contains no credentials, no cache-service integration, and no third-party
binary archive URL except the official Nix release used during packaging.

