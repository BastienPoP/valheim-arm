# Changelog

`latest` tracks `main` and is rebuilt weekly for security updates; a `X.Y.Z` tag
is one fixed build and is never rebuilt. See the README for what each tag means.

## [2.1.0] - 2026-10-04

### Added

- Automatic recovery for an install that has fallen too far behind to update
  itself. Steam refuses an anonymous login the request code for a manifest that
  is no longer current, so once a patch has shipped, every update of an older
  install fails with `state is 0x6 after update job` — permanently, with only a
  warning in the log, while the server keeps running the old build.

  On that error the local install state is now cleared and the update retried
  once with `validate`, which reuses the files on disk: a verification pass
  rather than a fresh 2 GB download. Set `STEAM_RESET_ON_FAILURE=false` to keep
  the old behaviour.

## [2.0.0] - 2026-10-04

### Changed

- **BREAKING — the server runs as UID 1000 instead of root.** A flaw in Valheim,
  Box64 or SteamCMD no longer starts out as root in the container.

  Upgrading from 1.x, the two bind-mounted directories still belong to root:

  - **Docker**: `sudo chown -R 1000:1000 ./server ./data`
  - **rootless Podman**: change no ownership. Container UID 0 is already mapped
    to your unprivileged account there, so map your own account in instead —
    `--userns=keep-id`, or `UserNS=keep-id` in a Quadlet unit. Chowning to 1000
    would hand your files to a subordinate UID you cannot read.

  The entrypoint checks both directories before anything else and prints the
  exact command to run, rather than failing later on something unhelpful.

### Added

- `UID` and `GID` build arguments, for a host account that is not 1000.

## [1.1.0] - 2026-10-03

### Added

- Weekly scheduled rebuild, without the layer cache, so Debian security updates
  reach the published image whether or not anything in the repository changes.
- Trivy scan on every build, failing on a *fixable* HIGH or CRITICAL finding.

### Changed

- `apt-get upgrade` at build time, so the image does not inherit whatever the
  base was missing on the day it was tagged.
- `latest` now also moves on a release tag, not only on a push to `main`.

### Removed

- `curl` and the dependency chain it brings in. It is installed to fetch
  SteamCMD and purged inside that same layer; nothing at runtime uses it.
- SteamCMD's graphical front end and update cache, 76 MB of no use to a headless
  server.

Together: 375 MB → 295 MB, 131 → 111 packages.

## 1.0.0 - 2026-09-23

First published image. Runs the official x86_64 **Linux** Valheim dedicated
server under Box64 — no Windows compatibility layer, no X server — with SteamCMD
update-on-start, world backups and a tunable Box64 profile.

Published as `latest` only; this version was never tagged in git.

[2.1.0]: https://github.com/BastienPoP/valheim-arm/releases/tag/v2.1.0
[2.0.0]: https://github.com/BastienPoP/valheim-arm/releases/tag/v2.0.0
[1.1.0]: https://github.com/BastienPoP/valheim-arm/releases/tag/v1.1.0
