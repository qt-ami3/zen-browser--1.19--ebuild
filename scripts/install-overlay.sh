#!/usr/bin/env bash
#
# install-overlay.sh — register this repository with Portage as the "zen" overlay.
#
# WHAT IT DOES (all steps are additive and idempotent — safe to re-run):
#   1. Resolves the overlay root from this script's own location.
#   2. Sanity-checks that the tree really is the zen overlay
#      (profiles/repo_name == "zen", metadata/layout.conf present).
#   3. Symlinks /var/db/repos/zen -> <overlay root> so ebuilds stay editable
#      without sudo.  Aborts if a REAL directory is already sitting there.
#   4. Writes /etc/portage/repos.conf/zen.conf.
#   5. Masks the competing packages in other overlays so `emerge zen-bin` is
#      never ambiguous:  www-client/zen-bin::guru  and
#      www-client/zen-browser-bin::edgets.
#   6. Adds the invoking user to the `portage` group so `pkgdev manifest` can
#      write into /var/cache/distfiles (root:portage 0775).
#   7. Points out how to install dev-util/pkgdev if it is missing.
#   8. Prints verification commands.
#
# USAGE:
#   ./scripts/install-overlay.sh          # will call sudo per-command as needed
#   sudo ./scripts/install-overlay.sh     # also works (root is detected)
#
# NOTHING here is destructive; no confirmation prompt is asked for.
#
set -euo pipefail

# ---------------------------------------------------------------- helpers ---
if [[ -t 1 ]]; then
	C_RESET=$'\033[0m'; C_INFO=$'\033[1;36m'; C_OK=$'\033[1;32m'
	C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
else
	C_RESET=''; C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''
fi

say()  { printf '%s==>%s %s\n'   "$C_INFO" "$C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n'  "$C_OK"   "$C_RESET" "$*"; }
warn() { printf '%swarn:%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
die()  { printf '%sfatal:%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }

# Run a command with root privileges, whether or not we already are root.
as_root() {
	if [[ ${EUID} -eq 0 ]]; then
		"$@"
	else
		sudo "$@"
	fi
}

# Write $2 (content) to $1 (path) as root, but only if it differs. Idempotent.
write_root_file() {
	local path=$1 content=$2
	if [[ -f ${path} ]] && [[ "$(cat "${path}")" == "${content}" ]]; then
		ok "${path} already up to date"
		return 0
	fi
	as_root install -d -m 0755 "$(dirname "${path}")"
	printf '%s\n' "${content}" | as_root tee "${path}" >/dev/null
	as_root chmod 0644 "${path}"
	ok "wrote ${path}"
}

# ------------------------------------------------------ 1. resolve myself ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)

REPO_LINK=/var/db/repos/zen
REPOS_CONF=/etc/portage/repos.conf/zen.conf
MASK_PATH=/etc/portage/package.mask
MASK_DIR_ENTRY="${MASK_PATH}/zen"

say "overlay root: ${REPO_ROOT}"

# --------------------------------------------------------- 2. sanity check ---
say "sanity-checking the overlay"

[[ -f ${REPO_ROOT}/profiles/repo_name ]] \
	|| die "${REPO_ROOT}/profiles/repo_name missing — is this really the zen overlay?"

REPO_NAME=$(head -n1 "${REPO_ROOT}/profiles/repo_name" | tr -d '[:space:]')
[[ ${REPO_NAME} == "zen" ]] \
	|| die "profiles/repo_name says '${REPO_NAME}', expected 'zen' — refusing to continue"

[[ -f ${REPO_ROOT}/metadata/layout.conf ]] \
	|| die "${REPO_ROOT}/metadata/layout.conf missing — incomplete overlay"

[[ -d ${REPO_ROOT}/www-client/zen-bin ]] \
	|| warn "${REPO_ROOT}/www-client/zen-bin does not exist yet (ebuild still being written?)"

if ! compgen -G "${REPO_ROOT}/www-client/zen-bin/zen-bin-*.ebuild" >/dev/null; then
	warn "no zen-bin-*.ebuild found yet — registration will still work, emerge will not"
fi

ok "repo_name=zen, layout.conf present"

# ------------------------------------------------------------ 3. symlink ----
say "linking ${REPO_LINK} -> ${REPO_ROOT}"

if [[ -e ${REPO_LINK} && ! -L ${REPO_LINK} ]]; then
	if [[ -d ${REPO_LINK} ]]; then
		die "${REPO_LINK} is a REAL directory, not a symlink.
       Refusing to clobber it. Inspect and move it aside yourself, e.g.:
         sudo mv ${REPO_LINK} ${REPO_LINK}.bak-\$(date +%Y%m%d%H%M%S)
       then re-run this script."
	fi
	die "${REPO_LINK} exists and is neither a symlink nor a directory — refusing to touch it"
fi

if [[ -L ${REPO_LINK} ]] && [[ "$(readlink -f "${REPO_LINK}")" == "${REPO_ROOT}" ]]; then
	ok "symlink already correct"
else
	as_root install -d -m 0755 /var/db/repos
	as_root ln -sfn "${REPO_ROOT}" "${REPO_LINK}"
	ok "symlink created/updated"
fi

# --------------------------------------------------------- 4. repos.conf ----
say "writing ${REPOS_CONF}"

ZEN_CONF='[zen]
location = /var/db/repos/zen
masters = gentoo
auto-sync = no
priority = 100'

write_root_file "${REPOS_CONF}" "${ZEN_CONF}"

# -------------------------------------------------------- 5. package.mask ---
say "masking competing zen packages in other overlays"

MASK_COMMENT_1='# Personal zen overlay (www-client/zen-bin::zen) is the single source of'
MASK_COMMENT_2='# truth for Zen Browser on this system. Mask the competing packages in'
MASK_COMMENT_3='# guru and edgets so portage can never pick them by accident.'
MASK_LINE_1='www-client/zen-bin::guru'
MASK_LINE_2='www-client/zen-browser-bin::edgets'

if [[ -d ${MASK_PATH} ]]; then
	# Preferred layout on this system: package.mask is a directory.
	MASK_CONTENT="${MASK_COMMENT_1}
${MASK_COMMENT_2}
${MASK_COMMENT_3}
${MASK_LINE_1}
${MASK_LINE_2}"
	write_root_file "${MASK_DIR_ENTRY}" "${MASK_CONTENT}"
elif [[ -f ${MASK_PATH} ]]; then
	warn "${MASK_PATH} is a plain file — appending instead of adding a directory entry"
	appended=0
	for line in "${MASK_LINE_1}" "${MASK_LINE_2}"; do
		if grep -qxF -- "${line}" "${MASK_PATH}"; then
			ok "already masked: ${line}"
		else
			if [[ ${appended} -eq 0 ]]; then
				printf '\n%s\n%s\n%s\n' \
					"${MASK_COMMENT_1}" "${MASK_COMMENT_2}" "${MASK_COMMENT_3}" \
					| as_root tee -a "${MASK_PATH}" >/dev/null
				appended=1
			fi
			printf '%s\n' "${line}" | as_root tee -a "${MASK_PATH}" >/dev/null
			ok "masked: ${line}"
		fi
	done
else
	# Neither file nor directory: create the directory form.
	as_root install -d -m 0755 "${MASK_PATH}"
	MASK_CONTENT="${MASK_COMMENT_1}
${MASK_COMMENT_2}
${MASK_COMMENT_3}
${MASK_LINE_1}
${MASK_LINE_2}"
	write_root_file "${MASK_DIR_ENTRY}" "${MASK_CONTENT}"
fi

# ------------------------------------------------------ 6. portage group ----
TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"
say "checking '${TARGET_USER}' membership in the portage group"

if ! getent group portage >/dev/null; then
	warn "there is no 'portage' group on this system — skipping"
elif id -nG "${TARGET_USER}" | tr ' ' '\n' | grep -qxF portage; then
	ok "${TARGET_USER} is already in the portage group"
else
	as_root gpasswd -a "${TARGET_USER}" portage
	ok "added ${TARGET_USER} to the portage group"
	warn "group membership is NOT active in this shell yet."
	printf '     Run `newgrp portage` in this terminal, or log out and back in,\n'
	printf '     before using `pkgdev manifest` (it writes to /var/cache/distfiles).\n'
fi

# ------------------------------------------------------------- 7. pkgdev ----
if command -v pkgdev >/dev/null 2>&1; then
	ok "dev-util/pkgdev is installed ($(command -v pkgdev))"
else
	warn "dev-util/pkgdev is NOT installed. scripts/bump.sh wants it."
	printf '     Suggested (NOT run by this script):\n'
	printf '       sudo emerge -av dev-util/pkgdev\n'
	printf '     pkgcheck comes in as a dependency of pkgdev.\n'
fi

# ------------------------------------------------------- 8. verification ----
printf '\n'
say "done. Verify with:"
printf '  portageq get_repo_path / zen\n'
printf '  emerge -pv www-client/zen-bin\n'
printf '\nIf the second command still shows ::guru or ::edgets, check %s\n' "${MASK_PATH}"
