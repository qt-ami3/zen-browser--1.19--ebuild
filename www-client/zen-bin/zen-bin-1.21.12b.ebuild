# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit desktop optfeature xdg

DESCRIPTION="Firefox-based browser built for calm, focused and productive browsing"
HOMEPAGE="https://zen-browser.app/ https://github.com/zen-browser/desktop"
SRC_URI="https://github.com/zen-browser/desktop/releases/download/${PV}/zen.linux-x86_64.tar.xz -> ${P}.tar.xz"
S="${WORKDIR}/zen"

LICENSE="MPL-2.0"
SLOT="0"
KEYWORDS="-* ~amd64"
IUSE="+wayland"

RESTRICT="bindist mirror strip"
QA_PREBUILT="opt/zen/*"

# Nothing is compiled or linked here, so there is no DEPEND; RDEPEND is all
# that matters.
#
# ffmpeg: libxul.so in 1.21.12b dlopens libavcodec.so.53 through .62, so plain
# media-video/ffmpeg (soname 62 as of ffmpeg-8.x) is enough -- same dependency
# gentoo's www-client/firefox-bin uses.  If a future bump ever regresses to a
# maximum of soname 61, the fix is media-video/ffmpeg-compat:7 *plus* a
# /usr/bin/zen wrapper script that prepends /usr/lib/ffmpeg7/$(get_libdir) to
# LD_LIBRARY_PATH: that package installs off the default linker path and ships
# no ld.so.conf.d entry, and ffmpeg-compat.eclass only exports PKG_CONFIG_PATH,
# which does nothing for a prebuilt binary.
#
# This list was derived from the shipped binaries rather than copied: every
# entry below backs a soname in `objdump -p` DT_NEEDED across zen, zen-bin,
# libxul.so and the helper binaries, or a library libxul.so dlopens by name.
# guru's ebuild additionally carries net-print/cups, x11-libs/libXtst and
# dev-libs/expat -- none of those appear in either set (printing goes through
# gtk+), so they are deliberately absent here.
#
# nspr/nss are bundled under /opt/zen, but DT_NEEDED names them unqualified
# and the loader can fall through to the system copies, so they stay declared.
RDEPEND="
	app-accessibility/at-spi2-core:2
	dev-libs/glib:2
	dev-libs/nspr
	dev-libs/nss
	media-libs/alsa-lib
	media-libs/fontconfig
	media-libs/freetype
	media-libs/mesa
	media-video/ffmpeg
	sys-apps/dbus
	virtual/freedesktop-icon-theme
	x11-libs/cairo
	x11-libs/gdk-pixbuf:2
	x11-libs/gtk+:3[wayland?,X(+)]
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
	x11-libs/libxcb
	x11-libs/pango
	|| (
		media-libs/libpulse
		media-sound/apulse
	)
	wayland? (
		dev-libs/wayland
		x11-libs/libxkbcommon[wayland]
	)
"

src_install() {
	# Upstream ships a ready-made tree whose executables already carry the
	# right modes.  cp -a reproduces it verbatim; insinto + doins -r would
	# flatten the exec bits and force us to restore each one by hand.
	dodir /opt/zen
	cp -a "${S}"/. "${ED}"/opt/zen/ || die "failed to copy the zen tree"

	# cp -a also preserves ownership, and with FEATURES=userpriv the unpacked
	# tree belongs to the build user -- which portage would carry through to
	# the live filesystem.  Force it back to root.
	fowners -R root:root /opt/zen

	# Defensive normalisation only -- upstream already ships these 0755/0750.
	# The existence guards matter because the set of helper binaries shifts
	# between releases and fperms dies on anything missing.
	local exe
	for exe in zen zen-bin updater glxtest vaapitest vulkantest; do
		if [[ -e ${ED}/opt/zen/${exe} ]]; then
			fperms 0755 /opt/zen/${exe}
		fi
	done

	if [[ -e ${ED}/opt/zen/pingsender ]]; then
		fperms 0750 /opt/zen/pingsender
	fi

	# zen and zen-bin are byte-identical in this release; zen is the one
	# upstream documents as the entry point.
	dosym -r /opt/zen/zen /usr/bin/zen

	local size
	for size in 16 32 48 64 128; do
		if [[ -e browser/chrome/icons/default/default${size}.png ]]; then
			newicon -s ${size} browser/chrome/icons/default/default${size}.png zen.png
		fi
	done

	domenu "${FILESDIR}"/zen-bin.desktop

	# Portage owns updates, so switch the in-browser updater off.  The
	# tarball has no distribution/ directory; this creates it.
	insinto /opt/zen/distribution
	doins "${FILESDIR}"/policies.json
}

pkg_postinst() {
	xdg_pkg_postinst

	# libxul.so dlopens these by name; none is required to start the browser,
	# so they are suggestions rather than dependencies.
	optfeature "VA-API hardware video decoding" media-libs/libva
	optfeature "a VA-API driver for Intel graphics" media-libs/libva-intel-media-driver
	optfeature "screen sharing and remote desktop under Wayland" media-video/pipewire

	elog "The browser is started with the 'zen' command."
	elog "Profiles are kept in ~/.zen (or ~/.config/zen on newer releases) and"
	elog "are not removed when this package is unmerged."
}

pkg_postrm() {
	xdg_pkg_postrm
}
