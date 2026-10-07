# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

# Source-built Zen Browser. Zen ${PV} is built on Firefox 153.0.3
# (engine/config/milestone.txt; /opt/zen/platform.ini Milestone=153.0.3).
#
# Source model: the ebuild consumes a pre-baked "engine" tarball produced
# OUTSIDE the portage sandbox by scripts/bake-engine.sh (Zen's patch
# application is done by surfer, a Node tool that needs pnpm + network,
# which the sandbox forbids). Compilation itself is 100% from source with
# the user's toolchain and flags. See README.md next to this ebuild.

# Firefox 153 sets MINIMUM_RUST_VERSION=1.90.0 and no maximum.
#
# Gentoo's firefox-152.0.5 uses LLVM_COMPAT=( 21 22 ), but slot 22 is masked
# on this host by /etc/portage/package.mask/99-pin-llvm21.conf: media-libs/mesa
# (mesa_clc) needs libclc:21, and stray llvm-22 bits made libclc-22 vs
# libclc-21 unsatisfiable. Offering slot 22 here just makes llvm-r1 select a
# masked slot and the merge fails before it starts.
#
# Widen this back to ( 21 22 ) when that mask file goes away.
LLVM_COMPAT=( 21 )
RUST_NEEDS_LLVM=1
RUST_MIN_VER=1.90.0

PYTHON_COMPAT=( python3_{12..14} )
PYTHON_REQ_USE="ncurses,sqlite,ssl"

# We only need virtx (Xvfb wrapper) for the PGO profiling run; dependency
# is added manually under pgo? below.
VIRTUALX_REQUIRED="manual"

inherit check-reqs desktop flag-o-matic gnome2-utils linux-info llvm-r1 \
	multiprocessing optfeature pax-utils python-any-r1 rust toolchain-funcs \
	virtualx xdg

DESCRIPTION="Firefox-based browser built for calm browsing, compiled from source"
HOMEPAGE="https://zen-browser.app/ https://github.com/zen-browser/desktop"

# Pre-baked engine tarball. RESTRICT="fetch": it must already exist in
# ${DISTDIR}; pkg_nofetch explains how to generate it. PV is kept verbatim
# ("1.21.12b" is a legal Gentoo version with a single trailing letter) so it
# matches the upstream tag and www-client/zen-bin.
SRC_URI="zen-${PV}-engine.tar.xz"
S="${WORKDIR}/engine"

# Firefox platform code is MPL-2.0/GPL-2/LGPL-2.1 tri-licensed; Zen's
# additions are MPL-2.0.
LICENSE="MPL-2.0 GPL-2 LGPL-2.1"
SLOT="0"
# SURFER_COMPAT is hardcoded to x86_64 (matches upstream release builds).
KEYWORDS="-* ~amd64"

IUSE="+clang +dbus debug geckodriver hardened +jumbo-build +lto pgo
	+pulseaudio screencast selinux +system-ffmpeg vaapi +wayland"

# pgo? ( jumbo-build ): non-unified PGO builds are untested upstream and
# regularly broken (same constraint as www-client/firefox).
# wayland? ( dbus ): the wayland backend needs the dbus-based portal glue.
REQUIRED_USE="
	pgo? ( jumbo-build )
	wayland? ( dbus )
"

# fetch:   tarball is baked locally, never downloaded.
# mirror:  nothing to mirror.
# bindist: Zen branding; this is a personal overlay anyway.
# strip:   `mach package` output is already stripped; when USE=debug we pass
#          --disable-install-strip and want the symbols to survive portage.
# test:    tests are disabled at configure time.
RESTRICT="bindist fetch mirror strip test"

BDEPEND="${PYTHON_DEPS}
	$(llvm_gen_dep '
		llvm-core/clang:${LLVM_SLOT}
		llvm-core/llvm:${LLVM_SLOT}
		clang? (
			llvm-core/lld:${LLVM_SLOT}
			pgo? ( llvm-runtimes/compiler-rt-sanitizers:${LLVM_SLOT}[profile] )
		)
	')
	app-alternatives/awk
	app-arch/unzip
	app-arch/zip
	>=dev-lang/nasm-2.14
	dev-lang/perl
	>=dev-util/cbindgen-0.29.4
	net-libs/nodejs
	sys-devel/m4
	virtual/pkgconfig
	pgo? (
		${VIRTUALX_DEPEND}
		sys-devel/gettext
	)
"
# Rust dependency (>=1.90, rust or rust-bin, slot-matched to LLVM_COMPAT)
# is added automatically by the rust eclass via RUST_MIN_VER/RUST_NEEDS_LLVM.

# Runtime deps: derived from the objdump-verified list in our zen-bin
# ebuild (same upstream version), plus USE-conditional extras. All Mozilla
# vendored libs (icu, libvpx, av1, harfbuzz, png/jpeg/webp, pixman, zlib,
# nss/nspr, ...) stay BUNDLED — no --with-system-* — because Zen's pins are
# routinely ahead of Gentoo's and mismatches cause subtle breakage; see
# README.md. nss/nspr remain declared because DT_NEEDED names them
# unqualified and the loader can fall through to the system copies.
#
# The toolkit is always built with X11 support (wayland ADDS the wayland
# backend), hence the unconditional X libs.
COMMON_DEPEND="
	>=app-accessibility/at-spi2-core-2.46.0:2
	dev-libs/glib:2
	dev-libs/nspr
	dev-libs/nss
	media-libs/alsa-lib
	media-libs/fontconfig
	media-libs/freetype
	media-libs/mesa
	virtual/freedesktop-icon-theme
	virtual/opengl
	x11-libs/cairo[X]
	x11-libs/gdk-pixbuf:2
	x11-libs/gtk+:3[X,wayland?]
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
	x11-libs/libxcb:=
	x11-libs/pango
	dbus? ( sys-apps/dbus )
	pulseaudio? (
		|| (
			media-libs/libpulse
			>=media-sound/apulse-0.1.12-r4[sdk]
		)
	)
	selinux? ( sec-policy/selinux-mozilla )
	wayland? (
		dev-libs/wayland
		x11-libs/libxkbcommon[wayland]
	)
"

# !!www-client/zen-bin: STRONG blocker. zen-bin owns /opt/zen and
# /usr/bin/zen — the exact paths this package installs. Portage must refuse
# to co-install rather than silently collide. Installing this package means
# unmerging zen-bin first (see README.md).
#
# ffmpeg/pipewire/libva are dlopen()ed by libxul at runtime, never linked,
# so they are RDEPEND-only and unversioned.
RDEPEND="${COMMON_DEPEND}
	!!www-client/zen-bin
	screencast? ( media-video/pipewire )
	system-ffmpeg? ( media-video/ffmpeg )
	vaapi? ( media-libs/libva )
"

DEPEND="${COMMON_DEPEND}
	x11-base/xorg-proto
	x11-libs/libICE
	x11-libs/libSM
"

# Everything under /opt/zen comes out of `mach package` (pre-stripped,
# $ORIGIN rpaths) or a direct dist/bin copy; silence the resulting QA
# scanner noise the same way the old ebuild and zen-bin do.
QA_PREBUILT="opt/zen/*"

llvm_check_deps() {
	if ! has_version -b "llvm-core/clang:${LLVM_SLOT}" ; then
		einfo "llvm-core/clang:${LLVM_SLOT} is missing! Cannot use LLVM slot ${LLVM_SLOT} ..." >&2
		return 1
	fi

	if use clang && ! tc-ld-is-mold ; then
		if ! has_version -b "llvm-core/lld:${LLVM_SLOT}" ; then
			einfo "llvm-core/lld:${LLVM_SLOT} is missing! Cannot use LLVM slot ${LLVM_SLOT} ..." >&2
			return 1
		fi
	fi

	if use pgo ; then
		if ! has_version -b "=llvm-runtimes/compiler-rt-sanitizers-${LLVM_SLOT}*[profile]" ; then
			einfo "=llvm-runtimes/compiler-rt-sanitizers-${LLVM_SLOT}*[profile] is missing!" >&2
			einfo "Cannot use LLVM slot ${LLVM_SLOT} ..." >&2
			return 1
		fi
	fi

	einfo "Using LLVM slot ${LLVM_SLOT} to build" >&2
}

# --- mozconfig helpers (borrowed from www-client/firefox) -------------------

mozconfig_add_options_ac() {
	debug-print-function ${FUNCNAME} "$@"
	[[ ${#} -lt 2 ]] && die "${FUNCNAME} requires at least two arguments"

	local reason=${1}
	shift

	local option
	for option in ${@} ; do
		echo "ac_add_options ${option} # ${reason}" >>${MOZCONFIG}
	done
}

mozconfig_add_options_mk() {
	debug-print-function ${FUNCNAME} "$@"
	[[ ${#} -lt 2 ]] && die "${FUNCNAME} requires at least two arguments"

	local reason=${1}
	shift

	local option
	for option in ${@} ; do
		echo "mk_add_options ${option} # ${reason}" >>${MOZCONFIG}
	done
}

mozconfig_use_enable() {
	debug-print-function ${FUNCNAME} "$@"
	[[ ${#} -lt 1 ]] && die "${FUNCNAME} requires at least one argument"

	local flag=$(use_enable "${@}")
	mozconfig_add_options_ac "$(use ${1} && echo +${1} || echo -${1})" "${flag}"
}

# Append "export VAR=value" lines to the mozconfig. mozconfig is sourced
# top-to-bottom on every mach invocation, so lines appended here override
# anything the surfer-generated part exported earlier (e.g. its preference
# for a ~/.mozbuild toolchain).
mozconfig_export() {
	local assignment
	for assignment in "${@}" ; do
		echo "export ${assignment}" >>${MOZCONFIG} || die
	done
}

# (Re-)export everything a bare mach invocation needs. Phase environments
# are restored from portage's saved env, but being explicit keeps
# standalone phase runs (`ebuild ... compile`) honest.
zen_mach_env() {
	export MOZCONFIG="${S}/mozconfig"
	export MOZBUILD_STATE_PATH="${WORKDIR}/mozbuild_state"

	# Suppress mach's end-of-build desktop notification...
	export MOZ_NOSPAM=1

	# ...and stub out notify-send anyway (belt and suspenders): mach's
	# notifier spawns the notification daemon, which probes /dev/udmabuf
	# and trips the sandbox, failing an otherwise-green merge.
	mkdir -p "${T}"/stubs || die
	ln -sf /bin/true "${T}"/stubs/notify-send || die
	export PATH="${T}/stubs:${PATH}"

	# Activate Zen's release-mode blocks in the surfer-generated mozconfig.
	# These are read by shell conditionals when the mozconfig is SOURCED,
	# so they must live in the environment, not at the bottom of the file.
	export ZEN_RELEASE=1
	export ZEN_RELEASE_BRANCH=release
	export SURFER_COMPAT=x86_64

	# Always bypass Zen's CI-style PGO flow (it expects pre-built profile
	# data at ~/artifact/merged.profdata). USE=pgo uses mach's own
	# MOZ_PGO=1 two-pass mode instead — see src_configure.
	export ZEN_GA_DISABLE_PGO=1
}

zen_set_checkreqs() {
	# A no-PGO build objdir peaks around 25-30 GiB with LTO; PGO keeps
	# instrumented + optimized artifacts around at once.
	if use pgo ; then
		CHECKREQS_DISK_BUILD="50G"
		CHECKREQS_MEMORY="12G"
	else
		CHECKREQS_DISK_BUILD="32G"
		CHECKREQS_MEMORY="8G"
	fi
	CHECKREQS_DISK_USR="500M"
}

pkg_pretend() {
	if [[ ${MERGE_TYPE} != binary ]] ; then
		zen_set_checkreqs
		check-reqs_pkg_pretend
	fi
}

pkg_setup() {
	if [[ ${MERGE_TYPE} != binary ]] ; then
		zen_set_checkreqs
		check-reqs_pkg_setup

		llvm-r1_pkg_setup
		rust_pkg_setup
		python-any-r1_pkg_setup

		# Avoid PGO profiling problems due to environment leakage —
		# harmless to clear for non-PGO builds too.
		unset \
			DBUS_SESSION_BUS_ADDRESS \
			DISPLAY \
			ORBIT_SOCKETDIR \
			SESSION_MANAGER \
			XAUTHORITY \
			XDG_CACHE_HOME \
			XDG_SESSION_COOKIE

		# Build system pokes /proc/self/oom_score_adj (bug #604394).
		addpredict /proc/self/oom_score_adj

		# Even with the notify-send stub, anything that probes
		# /dev/udmabuf must not fail the merge.
		addpredict /dev/udmabuf

		if use pgo ; then
			# The instrumented browser run touches all sorts of device
			# and proc nodes (same as www-client/firefox).
			addpredict /proc
			addpredict /dev
		fi

		if ! mountpoint -q /dev/shm ; then
			ewarn "/dev/shm is not mounted -- expect build failures!"
		fi

		# Ensure we use C locale when building (bug #746215).
		export LC_ALL=C
	fi

	CONFIG_CHECK="~SECCOMP"
	WARNING_SECCOMP="CONFIG_SECCOMP not set! This system will be unable to play DRM-protected content."
	linux-info_pkg_setup
}

pkg_nofetch() {
	eerror ""
	eerror "This ebuild consumes a pre-baked 'engine' source tree (Firefox +"
	eerror "Zen patches, applied by surfer outside the sandbox because surfer"
	eerror "needs pnpm and network access). Expected file:"
	eerror ""
	eerror "  ${DISTDIR}/zen-${PV}-engine.tar.xz"
	eerror ""
	eerror "Generate it from the overlay checkout:"
	eerror ""
	eerror "  /home/aknu/projects/zen_emerge_file/scripts/bake-engine.sh ${PV}"
	eerror ""
	eerror "then regenerate the Manifest from the overlay:"
	eerror ""
	eerror "  ebuild www-client/zen/${PF}.ebuild manifest"
	eerror ""
	eerror "See README.md in the package directory for the full rationale."
	eerror ""
}

src_prepare() {
	default

	[[ -f ${S}/mozconfig ]] || \
		die "engine/mozconfig missing — bake-engine.sh must run surfer far enough to generate it"

	# Make cargo respect MAKEOPTS.
	export CARGO_BUILD_JOBS="$(makeopts_jobs)"

	# Make LTO/PGO helper scripts respect MAKEOPTS instead of nproc.
	# Guarded: these paths move around between Firefox majors, and losing
	# the tweak only costs scheduling fairness, not correctness.
	local f
	for f in \
		build/moz.configure/lto-pgo.configure \
		third_party/chromium/build/toolchain/get_cpu_count.py \
		third_party/python/gyp/pylib/gyp/input.py
	do
		if [[ -f ${S}/${f} ]] ; then
			sed -i -e "s/multiprocessing.cpu_count()/$(makeopts_jobs)/" \
				"${S}/${f}" || die "Failed sedding multiprocessing.cpu_count in ${f}"
		else
			ewarn "${f} not found; MAKEOPTS clamp for it skipped"
		fi
	done

	# FEATURES=ccache wraps the compiler behind mozbuild's back; stop
	# mozbuild from trying to gather ccache stats itself.
	sed -i -e 's/ccache_stats = None/return None/' \
		"${S}"/python/mozbuild/mozbuild/controller/building.py \
		|| die "sed failed to disable ccache stats call"

	xdg_environment_reset
}

src_configure() {
	zen_mach_env

	# Show flags as set by portage before we touch them.
	einfo "Current CFLAGS:    ${CFLAGS:-no value set}"
	einfo "Current CXXFLAGS:  ${CXXFLAGS:-no value set}"
	einfo "Current LDFLAGS:   ${LDFLAGS:-no value set}"
	einfo "Current RUSTFLAGS: ${RUSTFLAGS:-no value set}"

	local have_switched_compiler=
	if use clang ; then
		einfo "Enforcing the use of clang due to USE=clang ..."

		local version_clang=$(clang --version 2>/dev/null | grep -F -- 'clang version' | awk '{ print $3 }')
		[[ -n ${version_clang} ]] && version_clang=$(ver_cut 1 "${version_clang}")
		[[ -z ${version_clang} ]] && die "Failed to read clang version!"

		if tc-is-gcc ; then
			have_switched_compiler=yes
		fi

		AR=llvm-ar
		CC=${CHOST}-clang-${version_clang}
		CXX=${CHOST}-clang++-${version_clang}
		NM=llvm-nm
		RANLIB=llvm-ranlib
	elif ! use clang && ! tc-is-gcc ; then
		have_switched_compiler=yes
		einfo "Enforcing the use of gcc due to USE=-clang ..."
		AR=gcc-ar
		CC=${CHOST}-gcc
		CXX=${CHOST}-g++
		NM=gcc-nm
		RANLIB=gcc-ranlib
	fi

	if [[ -n ${have_switched_compiler} ]] ; then
		# We switched active compiler: drop flags it does not understand.
		strip-unsupported-flags
	fi

	# AS is used in a non-standard way by upstream (bmo#1654031).
	export HOST_CC="$(tc-getBUILD_CC)"
	export HOST_CXX="$(tc-getBUILD_CXX)"
	export AS="$(tc-getCC) -c"

	# Configuration tests expect llvm-readelf output (bug #913130).
	READELF="llvm-readelf"

	tc-export CC CXX LD AR AS NM OBJDUMP RANLIB READELF PKG_CONFIG

	# python/mach/mach/mixin/process.py fails to detect SHELL.
	export SHELL="${EPREFIX}/bin/bash"

	# Keep mach state out of ~/.mozbuild.
	mkdir -p "${MOZBUILD_STATE_PATH}" || die

	# Pass MAKEOPTS to the build system.
	export MOZ_MAKE_FLAGS="${MAKEOPTS}"

	# Never let pip/mach reach for the network for its python environment.
	export PIP_NETWORK_INSTALL_RESTRICTED_VIRTUALENVS=mach
	export MACH_BUILD_PYTHON_NATIVE_PACKAGE_SOURCE="none"

	# Portage exports XARGS="xargs -r", which the build system's
	# check_prog() treats as a literal program path (the old ebuild also
	# saw a stale "gxargs" leak through). Force plain xargs everywhere.
	export XARGS="${EPREFIX}/usr/bin/xargs"

	# LTO is driven by USE=lto below; never let stray -flto in *FLAGS fight
	# the configure-level switches.
	filter-lto
	# Known-broken flags from the 1.19.9 attempt and www-client/firefox.
	filter-flags '-fomit-frame-pointer'       # mach overrides anyway
	filter-flags '-fvar-tracking-assignments' # GCC-only, breaks clang
	filter-flags '-fno-plt'                   # breaks some FF subdirs
	filter-flags -Werror=lto-type-mismatch -Werror=odr # bmo#1516758

	# =====================================================================
	# Append Gentoo policy to the surfer-generated mozconfig. mozconfig is
	# evaluated top-to-bottom and the LAST occurrence of an option wins, so
	# everything below overrides Zen's release defaults where they clash.
	# =====================================================================
	cat >> "${MOZCONFIG}" <<-EOF || die

		# ============================================================
		# Gentoo overrides appended by ${PF}.ebuild
		# ============================================================
	EOF

	# Hard-won fixes from the 1.19.9 attempt — do not drop:
	# --disable-bootstrap: use the system toolchain, never Mozilla's
	#   downloaded clang/rust.
	# --without-wasm-sandboxed-libraries: the WASI sysroot is normally
	#   fetched by bootstrap; we have neither network nor sys-devel/wasi-sdk.
	# --disable-clang-plugin: Zen's release mozconfig enables Mozilla's
	#   build-time lint plugin, which needs libclangASTMatchers that
	#   Gentoo's llvm-core/clang does not ship. No runtime impact.
	mozconfig_add_options_ac 'system toolchain' --disable-bootstrap
	mozconfig_add_options_ac 'no WASI sysroot available' --without-wasm-sandboxed-libraries
	mozconfig_add_options_ac 'gentoo clang lacks libclangASTMatchers' --disable-clang-plugin

	mozconfig_add_options_ac 'Gentoo default' \
		--disable-cargo-incremental \
		--disable-crashreporter \
		--disable-tests \
		--disable-updater \
		--enable-packed-relative-relocs \
		--enable-rust-simd \
		--enable-sandbox \
		--without-ccache

	# Stripping: RESTRICT=strip keeps portage's hands off /opt/zen, so make
	# the build system's behavior deterministic instead: strip at package
	# time unless the user asked for symbols (USE=debug or -g in CFLAGS).
	# This must be decided before filter-flags '-g*' below.
	if use debug || is-flag '-g*' ; then
		mozconfig_add_options_ac 'keep symbols' \
			--disable-install-strip \
			--disable-strip
	else
		mozconfig_add_options_ac 'strip at package time' --enable-install-strip
	fi

	# bindgen needs libclang regardless of the chosen compiler.
	mozconfig_add_options_ac 'gentoo default' \
		--with-libclang-path="$(llvm-config --libdir)"

	# Portage's XARGS breaks check_prog() (see export above); also pin it
	# at the configure level like www-client/firefox does.
	mozconfig_add_options_ac 'Gentoo default' "XARGS=${EPREFIX}/usr/bin/xargs"

	# amd64-only package; relr elf-hack is supported and beneficial here.
	filter-flags "-z,pack-relative-relocs"
	mozconfig_add_options_ac 'relr elf-hack' --enable-elf-hack=relr

	# Toolkit: X11 support is always built (the profile-run under Xvfb for
	# PGO needs it, and XWayland fallback is useful); wayland adds the
	# native backend.
	if use wayland ; then
		mozconfig_add_options_ac '+wayland' --enable-default-toolkit=cairo-gtk3-x11-wayland
	else
		mozconfig_add_options_ac '-wayland' --enable-default-toolkit=cairo-gtk3-x11-only
	fi

	# Audio: cubeb backend selection, same policy as www-client/firefox
	# (pulseaudio: the pulse backend also serves pipewire's pulse shim).
	local myaudiobackends=""
	use pulseaudio && myaudiobackends+="pulseaudio,"
	! use pulseaudio && myaudiobackends+="alsa,"
	mozconfig_add_options_ac '--enable-audio-backends' --enable-audio-backends="${myaudiobackends::-1}"

	mozconfig_use_enable dbus

	# ffmpeg is dlopen()ed at runtime; --disable-ffmpeg removes the decode
	# glue entirely (no h264/aac/etc).
	if use system-ffmpeg ; then
		mozconfig_add_options_ac '+system-ffmpeg' --enable-ffmpeg
	else
		mozconfig_add_options_ac '-system-ffmpeg' --disable-ffmpeg
	fi

	if use geckodriver ; then
		mozconfig_add_options_ac '+geckodriver' --enable-geckodriver
	else
		mozconfig_add_options_ac '-geckodriver' --disable-geckodriver
	fi

	! use jumbo-build && mozconfig_add_options_ac '-jumbo-build' --disable-unified-build

	if use hardened ; then
		mozconfig_add_options_ac '+hardened' --enable-hardening --enable-stl-hardening
		append-ldflags "-Wl,-z,relro -Wl,-z,now"

		# Increase the FORTIFY_SOURCE value (bug #910071).
		sed -i -e '/-D_FORTIFY_SOURCE=/s:2:3:' \
			"${S}"/build/moz.configure/toolchain.configure || die
	fi

	# LTO / linker selection (mirrors www-client/firefox).
	if use lto ; then
		if use clang ; then
			# Upstream only supports lld or mold with clang.
			if tc-ld-is-mold ; then
				# mold expects the -flto line via *FLAGS (bgo#923119).
				append-ldflags "-flto=thin"
				mozconfig_add_options_ac "mold selected by system" --enable-linker=mold
			else
				mozconfig_add_options_ac "+lto +clang" --enable-linker=lld
			fi
			mozconfig_add_options_ac '+lto' --enable-lto=cross,thin
		else
			# ThinLTO is broken with gcc (bmo#1644409); mold does not
			# support gcc+lto at all.
			mozconfig_add_options_ac '+lto' --enable-lto=full
			mozconfig_add_options_ac '+lto -clang' --enable-linker=bfd
		fi
	else
		# No LTO: still pin the linker so configure does not automagic.
		if tc-ld-is-mold ; then
			mozconfig_add_options_ac "mold selected by system" --enable-linker=mold
		elif use clang ; then
			mozconfig_add_options_ac "+clang" --enable-linker=lld
		else
			mozconfig_add_options_ac "-clang" --enable-linker=bfd
		fi
	fi

	# PGO: mach's built-in MOZ_PGO=1 three-phase mode (instrumented build →
	# profile run against the bundled build/pgo/profileserver.py workload →
	# optimized rebuild). Zen's own CI PGO flow stays disabled via
	# ZEN_GA_DISABLE_PGO=1 (exported in zen_mach_env) because it expects
	# pre-built profile data we do not have.
	if use pgo ; then
		mozconfig_add_options_ac '+pgo' MOZ_PGO=1

		if use clang ; then
			# Used in build/pgo/profileserver.py.
			export LLVM_PROFDATA="llvm-profdata"
		else
			# Attempt to fix pgo hanging with gcc (bgo#966309).
			export MOZ_REMOTE_SETTINGS_DEVTOOLS=1
		fi
	fi

	mozconfig_use_enable debug
	if use debug ; then
		mozconfig_add_options_ac '+debug' --disable-optimize
	else
		# Map portage's -O level onto MOZ_OPTIMIZE_FLAGS; -march etc. still
		# flow in via CFLAGS.
		if is-flag '-g*' ; then
			if use clang ; then
				mozconfig_add_options_ac 'from CFLAGS' --enable-debug-symbols=$(get-flag '-g*')
			else
				mozconfig_add_options_ac 'from CFLAGS' --enable-debug-symbols
			fi
		else
			mozconfig_add_options_ac 'Gentoo default' --disable-debug-symbols
		fi

		if is-flag '-O0' ; then
			mozconfig_add_options_ac "from CFLAGS" --enable-optimize=-O0
		elif is-flag '-O3' ; then
			mozconfig_add_options_ac "from CFLAGS" --enable-optimize=-O3
		elif is-flag '-O1' ; then
			mozconfig_add_options_ac "from CFLAGS" --enable-optimize=-O1
		elif is-flag '-Os' ; then
			mozconfig_add_options_ac "from CFLAGS" --enable-optimize=-Os
		else
			mozconfig_add_options_ac "Gentoo default" --enable-optimize=-O2
		fi
	fi

	# Debug/optimization levels were handled via configure above.
	filter-flags '-g*' '-O*'

	# Telemetry / data reporting off, unconditionally.
	mozconfig_add_options_mk 'privacy' \
		"MOZ_CRASHREPORTER=0" \
		"MOZ_DATA_REPORTING=0" \
		"MOZ_SERVICES_HEALTHREPORT=0" \
		"MOZ_TELEMETRY_REPORTING=0"

	# Toolchain exports appended LAST so they beat any `export CC=...` the
	# surfer-generated section may contain (it prefers ~/.mozbuild/clang
	# when present).
	mozconfig_export \
		"CC=${CC}" \
		"CXX=${CXX}" \
		"AR=${AR}" \
		"NM=${NM}" \
		"RANLIB=${RANLIB}"

	# Show the flags we ended up with.
	einfo "Build CFLAGS:    ${CFLAGS:-no value set}"
	einfo "Build CXXFLAGS:  ${CXXFLAGS:-no value set}"
	einfo "Build LDFLAGS:   ${LDFLAGS:-no value set}"
	einfo "Build RUSTFLAGS: ${RUSTFLAGS:-no value set}"

	# Handle EXTRA_ECONF and show a summary of every ac option, ours and
	# surfer's alike.
	local ac opt hash reason
	if [[ -n ${EXTRA_ECONF} ]] ; then
		IFS=\! read -a ac <<<${EXTRA_ECONF// --/\!}
		for opt in "${ac[@]}" ; do
			mozconfig_add_options_ac "EXTRA_ECONF" --${opt#--}
		done
	fi

	echo
	echo "=========================================================="
	echo "Building ${PF} with the following configuration"
	grep ^ac_add_options "${MOZCONFIG}" | while read ac opt hash reason ; do
		[[ -z ${hash} || ${hash} == \# ]] \
			|| die "error reading mozconfig: ${ac} ${opt} ${hash} ${reason}"
		printf "    %-40s  %s\n" "${opt}" "${reason:-upstream default}"
	done
	echo "=========================================================="
	echo

	./mach configure || die
}

src_compile() {
	cd "${S}" || die
	zen_mach_env

	local virtx_cmd=

	if use pgo ; then
		# Clean GNOME/XDG state out of the environment before the
		# instrumented profile run.
		gnome2_environment_reset

		addpredict /root
		virtx_cmd=virtx
	fi

	# The toolkit always includes X11 and the PGO profile run happens under
	# Xvfb, so pin the backend rather than letting gtk guess.
	local -x GDK_BACKEND=x11

	if use pgo ; then
		einfo "PGO build: instrumented compile -> profile run (Xvfb) -> optimized rebuild."
		einfo "This roughly doubles build time."
	fi

	${virtx_cmd} ./mach build --verbose || die "mach build failed"
}

src_install() {
	cd "${S}" || die
	zen_mach_env

	local dest="/opt/zen"
	dodir "${dest}"

	# Locate the objdir. The surfer mozconfig leaves MOZ_OBJDIR at mach's
	# default, an obj-<target-triple> directory at the top of the tree.
	local d objdir= bindir=
	for d in "${S}"/obj-*/dist/bin ; do
		if [[ -d ${d} && -x ${d}/zen ]] ; then
			bindir="${d}"
			objdir="${d%/dist/bin}"
			break
		fi
	done
	[[ -n ${bindir} ]] || die "couldn't find obj-*/dist/bin/zen — did the build succeed?"

	# xpcshell runs during `mach package`; pax-mark it (no-op on non-PaX).
	local f
	for f in xpcshell zen zen-bin plugin-container ; do
		[[ -e ${bindir}/${f} ]] && pax-mark m "${bindir}/${f}"
	done

	# Prefer `mach package` output: it dereferences the relative symlinks
	# dist/bin is riddled with, prunes test-only files and strips. Ask for
	# a plain tar container — compressing a tree we immediately unpack
	# again would waste several minutes.
	local pkg=
	export MOZ_PKG_FORMAT=tar
	if ./mach package ; then
		pkg=$(find "${objdir}/dist" -maxdepth 1 -type f \
			\( -name 'zen-*.tar' -o -name 'zen-*.tar.xz' -o -name 'zen-*.tar.bz2' -o -name 'zen-*.tar.gz' \) \
			2>/dev/null | head -n 1)
	else
		ewarn "'mach package' failed; falling back to a direct dist/bin copy."
	fi

	if [[ -n ${pkg} && -e ${pkg} ]] ; then
		einfo "Installing from packaged tarball: ${pkg##*/}"
		tar -xf "${pkg}" -C "${ED}${dest}" --strip-components=1 || die "extract failed"
	else
		einfo "Copying directly from ${bindir}"
		# dist/bin has relative symlinks pointing back into the build tree
		# (application.ini, dependentlibs.list, *.sys.mjs, ...) which would
		# dangle once installed. tar -h dereferences them the same way
		# mach package does. cp -aL is NOT equivalent: -a implies -d,
		# which conflicts with -L in GNU coreutils.
		tar -C "${bindir}" -chf - . | tar -C "${ED}${dest}" -xf - || die "copy failed"
	fi

	# Both install paths run tar as the build user; with FEATURES=userpriv
	# that ownership would leak through to the live filesystem.
	fowners -R root:root "${dest}"

	# Existence-guarded: the helper binary set shifts between releases, and
	# some (updater, pingsender) are configured out of this build entirely.
	for f in zen zen-bin updater glxtest vaapitest vulkantest ; do
		if [[ -e ${ED}${dest}/${f} ]] ; then
			fperms 0755 "${dest}/${f}"
		fi
	done
	if [[ -e ${ED}${dest}/pingsender ]] ; then
		fperms 0750 "${dest}/pingsender"
	fi

	if use geckodriver ; then
		# mach package does not include geckodriver; take it from dist/bin.
		[[ -x ${bindir}/geckodriver ]] || die "USE=geckodriver but no geckodriver was built"
		exeinto "${dest}"
		doexe "${bindir}"/geckodriver
		dosym -r "${dest}"/geckodriver /usr/bin/geckodriver
	fi

	dosym -r "${dest}"/zen /usr/bin/zen

	# System-wide default prefs.
	local PREFS_DIR="${dest}/browser/defaults/preferences"
	if use vaapi ; then
		insinto "${PREFS_DIR}"
		newins - zen-gentoo-prefs.js <<-EOF || die
			// Installed by ${PF} (USE=vaapi)
			pref("media.ffmpeg.vaapi.enabled", true);
		EOF
	fi

	# Icons + desktop entry (same shape as www-client/zen-bin).
	local size
	for size in 16 32 48 64 128 ; do
		if [[ -e ${ED}${dest}/browser/chrome/icons/default/default${size}.png ]] ; then
			newicon -s ${size} \
				"${ED}${dest}/browser/chrome/icons/default/default${size}.png" zen.png
		fi
	done

	make_desktop_entry "zen %u" "Zen Browser" "zen" \
		"Network;WebBrowser;" \
		"MimeType=text/html;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;\nStartupWMClass=zen"

	# pax mark the installed copies too (packaging lost the objdir marks).
	for f in zen-bin plugin-container ; do
		[[ -e ${ED}${dest}/${f} ]] && pax-mark m "${ED}${dest}/${f}"
	done
}

pkg_postinst() {
	xdg_pkg_postinst

	optfeature "VA-API hardware video decoding driver for Intel graphics" \
		media-libs/libva-intel-media-driver
	optfeature "screen sharing and remote desktop under Wayland" \
		sys-apps/xdg-desktop-portal

	elog "The browser is started with the 'zen' command."
	elog "Profiles live in ~/.zen or ~/.config/zen and are not touched on unmerge."
	elog
	elog "This package and www-client/zen-bin both own /opt/zen and /usr/bin/zen;"
	elog "they block each other and cannot be installed together."
	if use pgo ; then
		elog "Built with PGO."
	fi
}

pkg_postrm() {
	xdg_pkg_postrm
}
