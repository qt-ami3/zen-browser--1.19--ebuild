# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

# Pre-baked engine source tarball model — see ./CLAUDE.md for design rationale
# and ../../scripts/bump.sh for how to regenerate the tarball.

PYTHON_COMPAT=( python3_{11,12,13} )
LLVM_COMPAT=( {18..21} )

inherit desktop xdg pax-utils flag-o-matic toolchain-funcs llvm-r1 \
	multiprocessing python-any-r1 check-reqs virtualx

MY_PV="${PV}b"
DESCRIPTION="Privacy-respecting Firefox-based browser, source build"
HOMEPAGE="https://zen-browser.app/ https://github.com/zen-browser/desktop"

# Engine tarball is pre-baked outside the build sandbox by ../../scripts/bump.sh
# RESTRICT="fetch" — must already be in /var/cache/distfiles. pkg_nofetch tells you how.
SRC_URI="zen-${PV}-engine.tar.xz"
S="${WORKDIR}/engine"

LICENSE="MPL-2.0"
SLOT="0"
KEYWORDS="-* ~amd64"

IUSE="
	+clang +jumbo-build +lto pgo
	+pipewire +pulseaudio +screencast +vaapi
	+wayland +dbus
	+system-ffmpeg
	geckodriver selinux
"

RESTRICT="bindist mirror fetch strip test"

# Build dependencies — Mozilla pins specific Rust/clang versions per FF release.
# FF 150.0 expects rust >= 1.75 and clang >= 18; bracket loosely.
# python-any-r1 eclass adds the python interpreter dep automatically.
BDEPEND="
	|| ( =sys-devel/gcc-13* >=sys-devel/gcc-14 )
	clang? (
		$(llvm_gen_dep 'llvm-core/clang:${LLVM_SLOT}=')
		$(llvm_gen_dep 'llvm-core/lld:${LLVM_SLOT}=')
	)
	|| ( >=dev-lang/rust-1.75 >=dev-lang/rust-bin-1.75 )
	dev-lang/perl
	dev-lang/nasm
	dev-util/cbindgen
	app-arch/unzip
	app-arch/zip
	sys-devel/m4
	virtual/pkgconfig
	pgo? ( ${VIRTUALX_DEPEND} )
"

# Runtime deps — modeled on www-client/firefox. Bundled libs (no system-icu/etc.)
# unless we add the flag explicitly later.
RDEPEND="
	dev-libs/glib:2
	dev-libs/nss
	dev-libs/nspr
	media-libs/alsa-lib
	media-libs/fontconfig
	media-libs/freetype
	media-libs/harfbuzz:=
	media-libs/libpng:0=[apng]
	media-libs/libjpeg-turbo:=
	media-libs/libwebp:=
	media-libs/mesa[wayland?,X(+)]
	sys-apps/dbus
	sys-libs/zlib
	x11-libs/cairo[X(+)]
	x11-libs/gdk-pixbuf:2
	x11-libs/gtk+:3[wayland?,X(+)]
	x11-libs/libdrm
	x11-libs/libX11
	x11-libs/libXcomposite
	x11-libs/libXcursor
	x11-libs/libXdamage
	x11-libs/libXext
	x11-libs/libXfixes
	x11-libs/libXi
	x11-libs/libXrandr
	x11-libs/libXrender
	x11-libs/libXScrnSaver
	x11-libs/libXt
	x11-libs/libxcb
	x11-libs/libxkbcommon[wayland?]
	x11-libs/pango
	x11-libs/pixman
	dbus? ( dev-libs/dbus-glib )
	pipewire? ( media-video/pipewire:= )
	pulseaudio? ( media-libs/libpulse )
	screencast? ( media-video/pipewire:= )
	system-ffmpeg? ( media-video/ffmpeg:= )
	vaapi? ( media-libs/libva:=[wayland?,X(+)] )
	wayland? ( dev-libs/wayland )
	selinux? ( sec-policy/selinux-mozilla )
"

DEPEND="${RDEPEND}
	x11-base/xorg-proto
"

QA_PREBUILT="opt/zen/zen
	opt/zen/zen-bin
	opt/zen/glxtest
	opt/zen/vaapitest
	opt/zen/*.so"

# Resource requirements: FF builds need a lot of disk + RAM. check-reqs warns.
# PGO doubles the disk requirement (instrumented + optimized objdirs).
CHECKREQS_DISK_BUILD="32G"
CHECKREQS_DISK_USR="500M"
CHECKREQS_MEMORY="8G"

pkg_pretend() {
	if use pgo; then
		CHECKREQS_DISK_BUILD="50G"
		CHECKREQS_MEMORY="12G"
	fi
	if [[ ${MERGE_TYPE} != binary ]]; then
		check-reqs_pkg_pretend
	fi
}

pkg_setup() {
	if [[ ${MERGE_TYPE} != binary ]]; then
		python-any-r1_pkg_setup
		llvm-r1_pkg_setup
		check-reqs_pkg_setup

		# mach calls notify-send at end of build; the notification-daemon
		# probes /dev/udmabuf (kernel direct-memory-buffer interface). Harmless
		# to deny it, but portage marks the merge failed on any sandbox
		# violation. Permit the access to keep the build green.
		addpredict /dev/udmabuf
	fi
}

pkg_nofetch() {
	eerror ""
	eerror "This ebuild expects a pre-baked engine tarball at:"
	eerror "  ${DISTDIR}/${A}"
	eerror ""
	eerror "Generate it with the bump script:"
	eerror "  ~/zen-overlay-staging/scripts/bump.sh ${MY_PV}"
	eerror ""
	eerror "or, if the overlay is already at /var/db/repos/local:"
	eerror "  /var/db/repos/local/scripts/bump.sh ${MY_PV}"
	eerror ""
	eerror "See ./CLAUDE.md in the package directory for full design rationale."
	eerror ""
}

src_prepare() {
	default

	local mozconfig="${S}/mozconfig"
	[[ -f ${mozconfig} ]] || die "engine/mozconfig missing — was bump.sh's mozconfig step skipped?"

	# Filter CFLAGS that Firefox's build system rejects or that break specific
	# subdirectories. flag-o-matic helpers are conservative.
	strip-flags
	filter-flags '-fomit-frame-pointer'      # mach overrides anyway
	filter-flags '-fvar-tracking-assignments' # GCC-only, breaks clang
	filter-flags '-fno-plt'                   # known to break some FF subdirs

	# Append portage policy + USE-driven options to the surfer-generated mozconfig.
	cat >> "${mozconfig}" <<-EOF

		# ============================================================
		# Gentoo overrides (ebuild-injected)
		# ============================================================

		# Disable Mozilla's bootstrap (downloads its own clang/rust/etc.)
		# We rely on system toolchain via Gentoo deps.
		ac_add_options --disable-bootstrap

		# WASM-sandboxed libraries need a WASI sysroot that bootstrap normally
		# fetches. Disable until we wire up sys-devel/wasi-sdk or similar.
		# Phase 2 work: re-enable for the security hardening it provides.
		ac_add_options --without-wasm-sandboxed-libraries

		# Override stale XARGS detection (something in env passes "gxargs -r"
		# as a literal program path; force just plain xargs).
		export XARGS=xargs
		unset GXARGS

		# Zen's release mozconfig enables --enable-clang-plugin (Mozilla-specific
		# build-time lint analyzer). It needs libclangASTMatchers etc., which
		# Gentoo's llvm-core/clang doesn't ship. Disable; no runtime impact.
		ac_add_options --disable-clang-plugin

		# Install paths
		ac_add_options --prefix=/usr
		ac_add_options --libdir=/usr/$(get_libdir)

		# We don't want the built-in updater; portage owns updates
		ac_add_options --disable-updater

		# Skip tests in production build
		ac_add_options --disable-tests

		# Crashreporter: disabled (no symbol upload, no mozsoft account)
		ac_add_options --disable-crashreporter

		# Parallelism: respect MAKEOPTS
		mk_add_options MOZ_PARALLEL_BUILD=$(makeopts_jobs)
		mk_add_options AUTOCLOBBER=1

		# Toolchain
		export CC="$(tc-getCC)"
		export CXX="$(tc-getCXX)"
		export AR="$(tc-getAR)"
		export NM="$(tc-getNM)"
		export RANLIB="$(tc-getRANLIB)"

		# Portage CFLAGS/CXXFLAGS/LDFLAGS — Firefox build will use these for most
		# subdirectories. Some files override (mach forces -O2 in places); that's
		# a Mozilla decision, not ours.
		export CFLAGS="${CFLAGS}"
		export CXXFLAGS="${CXXFLAGS}"
		export LDFLAGS="${LDFLAGS}"
		export RUSTFLAGS="\${RUSTFLAGS:-}"

		ac_add_options --enable-default-toolkit=cairo-gtk3$(usex wayland '-wayland' '')
	EOF

	# USE-driven mozconfig appends
	if use lto; then
		cat >> "${mozconfig}" <<-EOF
			ac_add_options --enable-lto=cross,thin
			export MOZ_LTO=cross,thin
		EOF
	else
		cat >> "${mozconfig}" <<-EOF
			ac_add_options --disable-lto
			unset MOZ_LTO
		EOF
	fi

	if use jumbo-build; then
		echo 'ac_add_options --enable-unified-build' >> "${mozconfig}"
	else
		echo 'ac_add_options --disable-unified-build' >> "${mozconfig}"
	fi

	if use clang; then
		local llvm_path
		llvm_path="$(get_llvm_prefix)"
		cat >> "${mozconfig}" <<-EOF
			export CC="${llvm_path}/bin/clang"
			export CXX="${llvm_path}/bin/clang++"
			ac_add_options --enable-linker=lld
			ac_add_options --with-libclang-path="${llvm_path}/$(get_libdir)"
			ac_add_options --with-clang-path="${llvm_path}/bin/clang"
		EOF
	fi

	# PGO is in IUSE but not yet wired — flag is a no-op in this version.
	# When wiring later: instrumented build → run workload → recompile with
	# --enable-profile-use=cross. See CLAUDE.md.

	if use system-ffmpeg; then
		echo 'ac_add_options --enable-ffmpeg' >> "${mozconfig}"
	fi

	if use geckodriver; then
		echo 'ac_add_options --enable-geckodriver' >> "${mozconfig}"
	else
		echo 'ac_add_options --disable-geckodriver' >> "${mozconfig}"
	fi

	# Always disable Mozilla's telemetry/data-reporting at compile time
	cat >> "${mozconfig}" <<-EOF
		ac_add_options MOZ_DATA_REPORTING=
		ac_add_options MOZ_TELEMETRY_REPORTING=
		mk_add_options MOZ_DATA_REPORTING=
		mk_add_options MOZ_TELEMETRY_REPORTING=
	EOF

	einfo "Final mozconfig:"
	sed 's/^/  /' "${mozconfig}" | head -80
	einfo "  (truncated; full mozconfig in ${mozconfig})"
}

src_configure() { :; }   # mozconfig drives the configure step inside mach

src_compile() {
	cd "${S}" || die

	# Stub out notify-send — mach calls it at end of build for a desktop
	# notification, which spawns notification-daemon, which probes /dev/udmabuf
	# and trips the sandbox. Stubbing prevents the violation entirely.
	mkdir -p "${T}/stubs"
	ln -sf /bin/true "${T}/stubs/notify-send"
	local -x PATH="${T}/stubs:${PATH}"

	# Activate Zen's release-mode mozconfig blocks
	local -x ZEN_RELEASE=1
	local -x ZEN_RELEASE_BRANCH=release
	local -x SURFER_COMPAT=x86_64
	# Disable Zen's CI-style PGO logic (which expects pre-built profile data
	# at ~/artifact/merged.profdata). We use mach's MOZ_PGO=1 instead, which
	# does the instrumented->workload->optimized two-pass internally.
	local -x ZEN_GA_DISABLE_PGO=1

	if use pgo; then
		local -x MOZ_PGO=1
		einfo "PGO build: instrumented compile -> profile workload (xvfb) -> optimized rebuild"
		einfo "This roughly doubles build time. Now is a good time to walk away."
		virtx ./mach build || die "mach PGO build failed"
	else
		./mach build || die "mach build failed"
	fi
}

src_install() {
	cd "${S}" || die

	# Same notify-send stub as src_compile — mach package may also notify.
	mkdir -p "${T}/stubs"
	ln -sf /bin/true "${T}/stubs/notify-send"
	local -x PATH="${T}/stubs:${PATH}"

	local -x ZEN_RELEASE=1
	local -x ZEN_RELEASE_BRANCH=release
	local -x SURFER_COMPAT=x86_64
	local -x ZEN_GA_DISABLE_PGO=1

	local dest="/opt/zen"
	dodir "${dest}"

	# Locate the build output. dist/bin/ has all runtime files and is
	# always present after a successful build. dist/<pkg>.tar.{xz,bz2} only
	# exists if `mach package` ran successfully.
	local objdir bindir pkg
	for d in obj-*/dist/bin; do
		if [[ -d ${d} && -x ${d}/zen ]]; then
			bindir="${d}"
			objdir="${d%/dist/bin}"
			break
		fi
	done
	[[ -n ${bindir} ]] || die "couldn't find obj-*/dist/bin/zen — did the build succeed?"

	# Prefer the packaged tarball (post-strip, smaller); fall back to direct
	# copy from dist/bin/ if mach package can't run (e.g. virtualenv missing
	# after a partial-recovery resume).
	if ./mach package 2>/dev/null; then
		pkg=$(find "${objdir}/dist" -maxdepth 1 \( -name 'zen-*.tar.xz' -o -name 'zen-*.tar.bz2' \) 2>/dev/null | head -1)
	fi

	if [[ -n ${pkg} && -e ${pkg} ]]; then
		einfo "Installing from packaged tarball: ${pkg##*/}"
		tar -xf "${pkg}" -C "${ED}${dest}" --strip-components=1 || die "extract failed"
	else
		einfo "mach package unavailable; copying directly from ${bindir}"
		# dist/bin/ has relative symlinks pointing back into the build tree
		# (application.ini, dependentlibs.list, .sys.mjs files, etc.) which
		# would dangle in the install dir. mach package dereferences these;
		# we replicate via tar -h. cp -aL is unreliable because -a's -d
		# conflicts with -L in GNU coreutils.
		tar -C "${bindir}" -chf - . | tar -C "${ED}${dest}" -xf - || die "copy failed"
	fi

	fperms 0755 "${dest}/zen" "${dest}/zen-bin"
	[[ -e ${ED}${dest}/glxtest ]] && fperms 0755 "${dest}/glxtest"
	[[ -e ${ED}${dest}/vaapitest ]] && fperms 0755 "${dest}/vaapitest"

	# Symlink into PATH
	dosym "../..${dest}/zen" "/usr/bin/zen"

	# Desktop entry — newicon takes an absolute (or cwd-relative) path
	local icon_src="${ED}${dest}/browser/chrome/icons/default/default128.png"
	if [[ -e ${icon_src} ]]; then
		newicon -s 128 "${icon_src}" "zen.png"
	fi

	make_desktop_entry "/usr/bin/zen %u" "Zen Browser" "zen" \
		"Network;WebBrowser;" \
		"MimeType=text/html;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;\nStartupWMClass=zen"

	# pax mark for hardened systems (no-op elsewhere)
	pax-mark m "${ED}${dest}/zen-bin" || true
}

pkg_postinst() {
	xdg_pkg_postinst
	elog ""
	elog "Zen has been installed to /opt/zen"
	elog "Profile and configuration live at ~/.config/zen/"
	if use pgo; then
		elog "Built with PGO."
	fi
	elog ""
}
