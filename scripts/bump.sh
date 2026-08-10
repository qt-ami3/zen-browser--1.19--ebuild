#!/usr/bin/env bash
#
# bump.sh — bump www-client/zen-bin in this overlay to a new upstream version.
#
# WHAT IT DOES (non-destructive; the old ebuild is COPIED, never moved):
#   1. Validates the version string  (must look like 1.21.13b).
#   2. HEAD-checks the upstream release asset BEFORE touching any file, so a
#      typo or an unpublished release fails fast:
#        https://github.com/zen-browser/desktop/releases/download/<V>/zen.linux-x86_64.tar.xz
#      GitHub 302-redirects release assets to objects.githubusercontent.com,
#      hence curl -L.
#   3. Copies the highest existing zen-bin-*.ebuild (sort -V) to the new
#      version.  If the target ebuild already exists it says so and carries on
#      to the manifest step, so re-running on the current version is a no-op.
#   4. Regenerates the Manifest — `pkgdev manifest` preferred (runs as you and
#      needs group `portage` for /var/cache/distfiles); falls back to
#      `sudo ebuild ... manifest`, which leaves a root-owned Manifest in the
#      git tree (the chown fix is printed).
#   5. Runs `pkgcheck scan` if available (advisory only, never fatal).
#   6. Prints the emerge + git commands to finish the bump.
#
# USAGE:
#   ./scripts/bump.sh 1.21.13b
#   ./scripts/bump.sh --help
#
# Runs entirely as your user; sudo is only used for the pkgdev-less fallback.
#
set -euo pipefail

# ---------------------------------------------------------------- helpers ---
if [[ -t 1 ]]; then
	C_RESET=$'\033[0m'; C_INFO=$'\033[1;36m'; C_OK=$'\033[1;32m'
	C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
else
	C_RESET=''; C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''
fi

say()  { printf '%s==>%s %s\n'    "$C_INFO" "$C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n'   "$C_OK"   "$C_RESET" "$*"; }
warn() { printf '%swarn:%s %s\n'  "$C_WARN" "$C_RESET" "$*" >&2; }
die()  { printf '%sfatal:%s %s\n' "$C_ERR"  "$C_RESET" "$*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: ${0##*/} <version>

  <version>   upstream Zen Browser release tag, e.g. 1.21.13b
              (must match ^[0-9]+\\.[0-9]+\\.[0-9]+b\$)

Options:
  -h, --help  show this help and exit

Example:
  ${0##*/} 1.21.13b
EOF
}

# ------------------------------------------------------------- arguments ----
if [[ $# -eq 0 ]]; then
	usage >&2
	exit 1
fi

case "$1" in
	-h|--help) usage; exit 0 ;;
esac

[[ $# -eq 1 ]] || { usage >&2; die "expected exactly one argument, got $#"; }

VERSION=$1

if [[ ! ${VERSION} =~ ^[0-9]+\.[0-9]+\.[0-9]+b$ ]]; then
	die "'${VERSION}' is not a valid Zen version.
       Expected MAJOR.MINOR.PATCH followed by a literal 'b', e.g. 1.21.13b
       (upstream tags every stable release with the trailing 'b')."
fi

# ------------------------------------------------------------ locations ----
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)
PKG_DIR="${REPO_ROOT}/www-client/zen-bin"
NEW_EBUILD="${PKG_DIR}/zen-bin-${VERSION}.ebuild"

[[ -d ${PKG_DIR} ]] || die "package directory not found: ${PKG_DIR}"

ASSET_URL="https://github.com/zen-browser/desktop/releases/download/${VERSION}/zen.linux-x86_64.tar.xz"

# ------------------------------------------------ 1. upstream HEAD check ----
say "checking upstream asset for ${VERSION}"
printf '    %s\n' "${ASSET_URL}"

command -v curl >/dev/null 2>&1 || die "curl is not installed — cannot verify the release asset"

if ! curl -fsIL --retry 2 "${ASSET_URL}" >/dev/null; then
	die "upstream asset not reachable for ${VERSION}.
       Either the release does not exist yet, the tag is spelled differently,
       or you are offline. Nothing has been changed.
       Check: https://github.com/zen-browser/desktop/releases"
fi
ok "upstream asset exists"

# ---------------------------------------------------- 2. create the ebuild --
if [[ -f ${NEW_EBUILD} ]]; then
	say "zen-bin-${VERSION}.ebuild already exists — skipping copy, going straight to the Manifest"
else
	# Highest existing version wins as the template.
	mapfile -t EXISTING < <(
		find "${PKG_DIR}" -maxdepth 1 -type f -name 'zen-bin-*.ebuild' -printf '%f\n' \
			| sort -V
	)

	[[ ${#EXISTING[@]} -gt 0 ]] \
		|| die "no existing zen-bin-*.ebuild in ${PKG_DIR} to use as a template.
       Write the first one by hand, then bump.sh can take over."

	TEMPLATE="${EXISTING[-1]}"
	say "copying ${TEMPLATE} -> zen-bin-${VERSION}.ebuild"
	cp -- "${PKG_DIR}/${TEMPLATE}" "${NEW_EBUILD}"
	ok "created ${NEW_EBUILD}"
	printf '    (the old ebuild is kept until the new one is proven)\n'
fi

# -------------------------------------------------------- 3. the Manifest ---
say "regenerating the Manifest"

MANIFEST_ROOT_OWNED=0

if command -v pkgdev >/dev/null 2>&1; then
	if ( cd "${PKG_DIR}" && pkgdev manifest ); then
		ok "Manifest regenerated with pkgdev"
	else
		die "pkgdev manifest failed.
       If it complained about /var/cache/distfiles being unwritable you are
       probably not in the 'portage' group yet in THIS shell. Try:
         newgrp portage      (or log out and back in)"
	fi
else
	warn "dev-util/pkgdev is not installed — falling back to 'sudo ebuild ... manifest'"
	printf '     Install it later with:  sudo emerge -av dev-util/pkgdev\n'
	command -v ebuild >/dev/null 2>&1 || die "neither pkgdev nor ebuild is available"

	sudo ebuild "${NEW_EBUILD}" manifest \
		|| die "ebuild manifest failed for ${NEW_EBUILD}"
	MANIFEST_ROOT_OWNED=1
	ok "Manifest regenerated with ebuild(1)"
fi

if [[ ${MANIFEST_ROOT_OWNED} -eq 1 ]]; then
	warn "that Manifest is now root-owned inside your git tree. Fix it with:"
	printf '       sudo chown %s:%s %s/Manifest\n' \
		"$(id -un)" "$(id -gn)" "${PKG_DIR}"
fi

# ------------------------------------------------------------ 4. pkgcheck ---
if command -v pkgcheck >/dev/null 2>&1; then
	say "running pkgcheck scan (advisory)"
	if ( cd "${PKG_DIR}" && pkgcheck scan ); then
		ok "pkgcheck found nothing worth reporting"
	else
		warn "pkgcheck reported issues (see above) — not fatal, but worth a look"
	fi
else
	printf '\n'
	warn "pkgcheck not installed — skipping QA scan (comes with dev-util/pkgdev)"
fi

# --------------------------------------------------------------- 5. next ----
printf '\n'
say "next steps"
printf '  sudo emerge -av =www-client/zen-bin-%s\n' "${VERSION}"
printf '\nOnce the build and the browser are verified:\n'
printf '  git -C %s add -A\n' "${REPO_ROOT}"
printf '  git -C %s commit -m "zen-bin: bump to %s"\n' "${REPO_ROOT}" "${VERSION}"
printf '\nAnd only then remove the superseded ebuild, e.g.:\n'
printf '  git -C %s rm www-client/zen-bin/zen-bin-<OLD>.ebuild\n' "${REPO_ROOT}"
