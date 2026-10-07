# zen overlay

Personal Gentoo overlay providing **`www-client/zen-bin`** — a repackaging of the official
[Zen Browser](https://zen-browser.app/) Linux binary tarball.

## Why this exists

Zen releases roughly weekly. The two third-party overlays that carry it lag badly:

| Source | Version (2026-08-09) |
|---|---|
| `guru::zen-bin` | 1.21.4b |
| `edgets::zen-browser-bin` | 1.21.5_beta |
| upstream | **1.21.12b** |

Owning the ebuild means a bump is one command instead of a wait.

## What this overlay does differently

**Correct ffmpeg dependency.** guru's ebuild carries an `ffmpeg-compat:7` workaround for
[bug 978430](https://bugs.gentoo.org/978430), where Zen couldn't find `libavcodec.so.61`. Two
things are wrong with it today:

1. It doesn't work. `ffmpeg_compat_setup 7` only exports `PKG_CONFIG_PATH`, which is meaningless
   for a prebuilt binary that never runs a compiler. `ffmpeg-compat:7` installs to
   `/usr/lib/ffmpeg7/lib64` with no `ld.so.conf.d` entry, so `dlopen` still can't find it. It
   would need an `LD_LIBRARY_PATH` wrapper.
2. It's no longer needed. Checking the actual 1.21.12b binary:

   ```
   $ strings libxul.so | grep -oE 'libavcodec\.so\.[0-9]+' | sort -uV
   libavcodec.so.53 ... libavcodec.so.61  libavcodec.so.62
   ```

   Soname 62 is `media-video/ffmpeg-8.x`. Upstream caught up after that bug was filed, so this
   ebuild just depends on plain `media-video/ffmpeg`, same as `www-client/firefox`.

If a future Zen release ever regresses below 61, the fix is `ffmpeg-compat:7` **plus** a wrapper —
the ebuild carries a comment to that effect.

**Wayland deps.** Neither existing ebuild declares any. This one has a `+wayland` USE flag pulling
`gtk+:3[wayland]`, `libxkbcommon[wayland]` and `dev-libs/wayland` — needed for niri.

**`vulkantest`.** Ships in the tarball but guru's ebuild doesn't handle it.

## Setup

```sh
./scripts/install-overlay.sh     # symlink + repos.conf + masks + portage group
newgrp portage                   # or re-login
sudo emerge -av dev-util/pkgdev
sudo emerge -av www-client/zen-bin
```

The overlay is registered by symlinking `/var/db/repos/zen` at this directory, so ebuilds stay
editable without `sudo` and stay in git.

## Bumping to a new release

```sh
./scripts/bump.sh 1.21.13b
sudo emerge -av =www-client/zen-bin-1.21.13b
```

`bump.sh` verifies the release exists upstream before touching anything, copies the previous
ebuild, and regenerates the Manifest. The old ebuild is kept until you've confirmed the new one
works — delete it and re-run `bump.sh` afterwards.

## Backups

Upgrading Zen migrates the profile schema **one way**. Once 1.21.12b has opened `~/.config/zen`,
the older 1.21.8b build will refuse to load it — each profile's `compatibility.ini` records the
last version that touched it. So rolling back means restoring the profile *and* the matching
browser tree together, which is what `zen-backup.sh` captures.

```sh
./scripts/zen-backup.sh backup --label pre-emerge   # close Zen first
./scripts/zen-backup.sh list
./scripts/zen-backup.sh verify latest
./scripts/zen-backup.sh restore <snapshot>          # destructive, prompts
./scripts/zen-backup.sh prune --keep 5              # destructive, prompts
```

Captured: `~/.config/zen` (profile), `~/.tarball-installations/zen`, `~/.local/bin/zen`, and any
`*zen*` desktop entries. Snapshots land in `$ZEN_BACKUP_DIR`, default
`~/.local/share/zen-snapshots`; a full one is ~400 MB and takes a couple of seconds.

Two things are deliberately **not** captured:

- `~/.cache/zen` — 1.2 GB and fully regenerable.
- `/opt/zen` — portage's, reproducible via `emerge`, and partly root-only (`pingsender` is
  `0750 root:root`, so a user-run `tar` cannot read it and the whole snapshot would abort).
  `meta.txt` records the merged version and the exact `emerge` line to restore it instead.

Safety properties worth knowing:

- **Refuses to run while Zen is open.** The profile's SQLite databases have open write-ahead logs,
  so a snapshot taken live can restore to a corrupt or stale profile. `--allow-running` overrides
  and marks the snapshot untrustworthy.
- `restore` takes an **automatic pre-restore snapshot** first, then **moves** the live directories
  aside as `*.replaced-<timestamp>` instead of deleting them — so a bad restore is still undoable.
- Every snapshot carries `SHA256SUMS`; `restore` refuses on a mismatch.
- An interrupted or failed backup **deletes its own partial snapshot** rather than leaving a
  half-written one that `list` would advertise and `restore` would trust.
- `meta.txt` records whether Zen was running during capture, so months later you can still tell
  whether a given snapshot is trustworthy.

## Layout

```
metadata/layout.conf          masters=gentoo, thin manifests
profiles/repo_name            "zen"
scripts/install-overlay.sh    register with portage (idempotent)
scripts/bump.sh               one-command release bump
scripts/zen-backup.sh         snapshot / restore profile + browser tree
scripts/remove-old-zen.sh     DESTRUCTIVE — retires the abandoned source-build attempt
www-client/zen-bin/           the ebuild, metadata.xml, files/, Manifest
```

## Notes

- Auto-update is disabled via `/opt/zen/distribution/policies.json` (`DisableAppUpdate`) — portage
  owns updates.
- Hardware video decode additionally needs `media-libs/libva-intel-media-driver`; `libva` alone
  installs no VA-API driver.
- `scripts/remove-old-zen.sh` cleans up the earlier abandoned source-build ebuild in
  `/var/db/repos/local`. Run it only after `zen-bin` is confirmed working.
