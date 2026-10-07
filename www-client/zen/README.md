# www-client/zen — source-built Zen Browser

Compiles Zen 1.21.12b (Firefox 153.0.3 platform + Zen patches) from source with
`mach`, the system clang/rust toolchain and your CFLAGS. Successor to the
abandoned 1.19.9 attempt that lived in `/var/db/repos/local/www-client/zen`;
the hard-won fixes from that attempt are carried forward (and marked as such in
ebuild comments).

## TL;DR

```sh
scripts/bake-engine.sh 1.21.12b                       # outside the sandbox
ebuild www-client/zen/zen-1.21.12b.ebuild manifest    # engine tarball is fetch-restricted
sudo emerge -av =www-client/zen-1.21.12b              # unmerges zen-bin via blocker prompt
```

Build cost on this host (8-core Lunar Lake, 30 GiB RAM): expect a few hours,
~30 GiB of objdir (~50 GiB with `USE=pgo`), LTO link peak ~10–14 GiB RAM.

## The source model: pre-baked engine tarball

Zen source = Firefox source + Zen patches, applied by **surfer**, a Node tool
that needs pnpm and network access. Portage's sandbox has no network, so
source *preparation* happens outside it: `scripts/bake-engine.sh` produces
`/var/cache/distfiles/zen-1.21.12b-engine.tar.xz`, and the ebuild is
`RESTRICT="fetch"` with a `pkg_nofetch` that tells you to run it.
*Compilation* still happens 100% inside the sandbox with your toolchain.

Alternatives considered and rejected (same analysis as the 1.19.9 attempt):
reimplementing surfer as bash-side patching (multi-week project), or allowing
network in the sandbox (non-reproducible, bad Gentoo citizenship).

### Engine tarball contract (bake-engine.sh MUST match this)

The ebuild assumes, exactly:

1. Tarball path: `/var/cache/distfiles/zen-${PV}-engine.tar.xz` with
   `PV=1.21.12b` **verbatim** — no stripping of the trailing `b` (unlike the
   1.19.9 ebuild's `MY_PV` dance; `1.21.12b` is a legal Gentoo version and
   matches both the upstream tag and our zen-bin package).
2. It unpacks to a single top-level directory named `engine/`
   (`S="${WORKDIR}/engine"`).
3. `engine/` is the *complete* Firefox+Zen tree: `mach`, `moz.configure`,
   `browser/`, `python/mozbuild/`, `third_party/`, `build/pgo/profileserver.py`
   (needed for `USE=pgo`) all at the top of `engine/`.
4. `engine/mozconfig` exists and is the surfer-generated release mozconfig
   (brand `release`, buildMode `release`). The ebuild **appends** its overrides
   to it and relies on last-occurrence-wins, so surfer's options must come
   first in the file. If surfer's part `export`s CC/CXX (it prefers
   `~/.mozbuild/clang` when present), that's fine — the ebuild appends its own
   toolchain exports after them.
5. The mozconfig must **not** set `MOZ_OBJDIR` to anything outside the tree.
   Default mach behavior (objdir `engine/obj-<target-triple>`) is expected;
   `src_install` locates the build via the `obj-*/dist/bin/zen` glob.
6. No build state: no `obj-*` directories, `mach clobber`ed, and building must
   not re-invoke surfer/pnpm/node_modules. (`net-libs/nodejs` is still in
   BDEPEND — the Firefox build itself uses node.)
7. These files must remain sed-able (the ebuild patches them; the
   `multiprocessing.cpu_count` ones are guarded with a warning, the ccache one
   dies): `python/mozbuild/mozbuild/controller/building.py`,
   `build/moz.configure/lto-pgo.configure`,
   `third_party/chromium/build/toolchain/get_cpu_count.py`,
   `third_party/python/gyp/pylib/gyp/input.py`,
   and `build/moz.configure/toolchain.configure` (for `USE=hardened`).
8. App naming comes from surfer's mozconfig (`--with-app-name=zen` etc.), so
   the built binary is `dist/bin/zen` and `mach package` yields
   `dist/zen-*.tar*`.
9. The tarball must be readable by portage (root-owned in distfiles is fine).

After baking, regenerate the Manifest (`ebuild ... manifest`) — the repo uses
thin manifests but a DIST entry is still required.

## CRITICAL: blocker against zen-bin

`www-client/zen-bin` owns `/opt/zen` and `/usr/bin/zen` — exactly what this
package installs. The ebuild declares a **strong blocker**
(`RDEPEND="!!www-client/zen-bin"`), so portage refuses to co-install instead of
colliding. **Installing zen means unmerging zen-bin.** Take a profile snapshot
first (`scripts/zen-backup.sh backup`) — profile schema migrations are one-way.

## Design decisions

- **Bundled Mozilla libs, no `--with-system-*`** (icu, libvpx, av1, harfbuzz,
  png/jpeg/webp, pixman, zlib, nss, nspr, libevent...): Zen's vendored pins are
  routinely ahead of Gentoo's; mismatches cause subtle breakage (TLS oddities
  with system NSS in particular). Only runtime-`dlopen`ed libraries (ffmpeg,
  pipewire, libva) come from the system, because those aren't version-locked at
  compile time. nss/nspr stay in RDEPEND anyway: DT_NEEDED names them
  unqualified and the loader can fall through to system copies.
- **Runtime dep list** is inherited from zen-bin's objdump-verified list for
  the same upstream version — more trustworthy than copying firefox's.
- **X11 always built, `wayland` adds the native backend**
  (`cairo-gtk3-x11-wayland` vs `cairo-gtk3-x11-only`). Wayland-only would break
  the PGO profile run (Xvfb) and lose the XWayland fallback for ~zero gain.
- **PGO is real now.** The 1.19.9 ebuild listed `pgo` in IUSE with a comment
  claiming it wasn't wired while `src_compile` *did* implement it. Resolved in
  favor of full wiring: `MOZ_PGO=1` via mozconfig, profile run under `virtx`
  (Xvfb), `compiler-rt-sanitizers[profile]` in BDEPEND,
  `REQUIRED_USE="pgo? ( jumbo-build )"`, and 50G/12G check-reqs. Zen's own CI
  PGO flow (expects pre-built `merged.profdata`) is always bypassed with
  `ZEN_GA_DISABLE_PGO=1`.
- **Stripping**: `RESTRICT=strip` keeps portage away from `/opt/zen`; instead
  the build strips at `mach package` time (`--enable-install-strip`) unless
  `USE=debug` or `-g` in CFLAGS, which switch to `--disable-strip` so symbols
  survive.
- **`mach package` install path with `tar -h` fallback** (carried from 1.19.9,
  it solves a real problem): `dist/bin` contains relative symlinks back into
  the build tree that would dangle once installed; `mach package` dereferences
  them, and the fallback replicates that with `tar -chf` (`cp -aL` is broken:
  `-a` implies `-d`, which conflicts with `-L`). `MOZ_PKG_FORMAT=tar` avoids
  pointlessly xz-compressing a tree we unpack again immediately.
- **`fowners -R root:root /opt/zen`**: both install paths run `tar` as the
  build user; with `FEATURES=userpriv` that ownership would otherwise leak to
  the live filesystem (lesson from zen-bin).
- **Telemetry/crash reporting/updater off unconditionally** — portage owns
  updates, so no `policies.json` is needed here (unlike zen-bin, whose binary
  ships the updater).
- **No L10n** beyond en-US, **no slotting**, **EME/Widevine left enabled**
  (bring your own CDM) — same rationale as the 1.19.9 CLAUDE.md.

### Hard-won fixes carried from the 1.19.9 attempt

| Fix | Why |
|---|---|
| `--disable-bootstrap` | use the system toolchain, never Mozilla's downloads |
| `--without-wasm-sandboxed-libraries` | the WASI sysroot is normally fetched by bootstrap |
| `--disable-clang-plugin` | needs libclangASTMatchers; Gentoo's clang doesn't ship it |
| `XARGS` pinned (env + mozconfig) | portage exports `XARGS="xargs -r"`, breaking `check_prog()` |
| notify-send stub + `addpredict /dev/udmabuf` | mach's build-done notification spawns the notification daemon, which probes `/dev/udmabuf` and trips the sandbox; `MOZ_NOSPAM=1` added on top |
| `ZEN_RELEASE=1`, `ZEN_RELEASE_BRANCH=release`, `SURFER_COMPAT=x86_64`, `ZEN_GA_DISABLE_PGO=1` | activate the release blocks in surfer's mozconfig; exported as *environment* in every mach phase because the mozconfig conditionals read them while the file is being sourced |
| `obj-*/dist/bin` glob + package-or-copy install | see stripping/install bullet above |

### What changed vs. the 1.19.9 ebuild (judged wrong or stale there)

- `MY_PV`/version-stripping: gone; `PV` is used verbatim.
- `pgo` IUSE contradiction: resolved (see above).
- `pipewire` USE flag: **dropped** — it gated the identical dep as
  `screencast`; one flag (`screencast`) now owns the pipewire dep.
- `system-ffmpeg` was append-only (`--enable-ffmpeg` when on, nothing when
  off): now wired both ways (`--disable-ffmpeg` removes the decode glue), so
  the flag actually does something in both states.
- Toolchain forcing now follows firefox-152 (versioned `${CHOST}-clang-NN`,
  `llvm-ar/nm/ranlib`, `strip-unsupported-flags` on compiler switch,
  `HOST_CC`/`AS` quirk, `llvm-readelf`) instead of raw `clang` from PATH.
- Old dep list drift fixed: gcc-13/14 pin dropped (irrelevant with
  USE=clang and wrong bracketing anyway), rust dep now via the `rust` eclass
  (`RUST_MIN_VER=1.90.0`, slot-matched to `LLVM_COMPAT=( 21 22 )`),
  `--with-libclang-path` now always set (bindgen needs libclang even with gcc).
- Added from firefox-152: `--without-ccache` + ccache-stats sed (host runs
  `FEATURES=ccache`), `MAKEOPTS` clamps for cargo/LTO helpers,
  `PIP_NETWORK_INSTALL_RESTRICTED_VIRTUALENVS=mach`, `LC_ALL=C`,
  `addpredict /proc/self/oom_score_adj` (+ `/proc` `/dev` for pgo), env
  unsets before PGO, `~SECCOMP` kernel check, packed relative relocs +
  `--enable-elf-hack=relr`, audio backend selection, EXTRA_ECONF passthrough
  and the configure summary table.
- `vulkantest` now handled; every `fperms` is existence-guarded (helper set
  shifts between releases, and updater/pingsender are configured out here).
- Explicit `./mach configure` in `src_configure` instead of `src_configure()
  { :; }` — earlier, clearer failures.

## Maintenance notes

- **Version bump**: copy the ebuild to the new PV, check
  `MINIMUM_RUST_VERSION` in `engine/python/mozboot/mozboot/util.py` and the
  Firefox major (`engine/config/milestone.txt`) — adjust `RUST_MIN_VER` /
  `LLVM_COMPAT` following whatever gentoo's www-client/firefox for that major
  uses. Then bake, manifest, emerge.
- **LTO link OOM**: `USE=-lto` is the safety valve.
- **PGO profile run fails in sandbox** (graphics/audio assumptions): fall back
  to `USE=-pgo`.
- **pkgcheck** is broken on this host (`/etc/portage/repos.conf/gentoo.conf`
  lacks `location=`); validation was `bash -n` + `xmllint` only.
- Surfer internals, failure-mode table, and the original design discussion:
  see `/var/db/repos/local/www-client/zen/CLAUDE.md` (1.19.9 era, still
  largely accurate).
