#!/bin/sh
# UniWRT online installer for OpenWrt 24.10+ / 25.x.
#
# One-line install:
#   wget -qO- https://gh-proxy.com/https://raw.githubusercontent.com/yanjinbin/uniwrt-luci/main/install.sh | sh
#   curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/yanjinbin/uniwrt-luci/main/install.sh | sh
#
# Optional:
#   ... | sh -s -- --activate
#   ... | sh -s -- v2.0.34
#   ... | sh -s -- v2.0.34 --activate
#
# GitHub downloads go through gh-proxy.com by default; override with GITHUB_PROXY=... or disable
# with GITHUB_PROXY=.

set -eu

REPO="${UNIWRT_REPO:-ox1d3x3/uniwrt-luci}"
TAG="latest"
ACTIVATE=0
GITHUB_PROXY="${GITHUB_PROXY:-https://gh-proxy.com/}"

TMP="$(mktemp -d)" || { printf '[-] cannot create a temp dir\n' >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT INT TERM

info() { printf '[*] %s\n' "$1"; }
ok()   { printf '[+] %s\n' "$1"; }
err()  { printf '[-] %s\n' "$1" >&2; }

usage() {
	cat <<-'EOF'
	usage: sh install.sh [tag] [--activate]

	  tag         theme release tag to install, default: latest
	  --activate  switch luci.main.mediaurlbase to /luci-static/uniwrt after install

	Environment:
	  GITHUB_PROXY=https://gh-proxy.com/  prefix used for GitHub/raw/API downloads
	  UNIWRT_REPO=owner/repo              release repository to query, default upstream
	EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--activate)
			ACTIVATE=1
			;;
		-h|--help)
			usage
			exit 0
			;;
		--*)
			err "unknown option: $1"
			usage >&2
			exit 1
			;;
		*)
			if [ "$TAG" != "latest" ]; then
				err "unexpected extra argument: $1"
				usage >&2
				exit 1
			fi
			TAG="$1"
			;;
	esac
	shift
done

fetch() {
	_u="$1"; _t="$2"; _o="$3"
	case "$_u" in
		https://github.com/*|https://api.github.com/*|https://objects.githubusercontent.com/*|https://release-assets.githubusercontent.com/*|https://raw.githubusercontent.com/*)
			[ -n "$GITHUB_PROXY" ] && _u="${GITHUB_PROXY}${_u}"
			;;
	esac
	if command -v uclient-fetch >/dev/null 2>&1; then
		if [ -n "$_o" ]; then uclient-fetch -T "$_t" -qO "$_o" "$_u" 2>/dev/null
		else uclient-fetch -T "$_t" -qO- "$_u" 2>/dev/null; fi
		return $?
	fi
	if command -v curl >/dev/null 2>&1; then
		if [ -n "$_o" ]; then
			curl -fsSL --proto =https --proto-redir =https --connect-timeout 10 --max-time "$_t" -o "$_o" "$_u" 2>/dev/null
		else
			curl -fsSL --proto =https --proto-redir =https --connect-timeout 10 --max-time "$_t" "$_u" 2>/dev/null
		fi
		return $?
	fi
	if command -v wget >/dev/null 2>&1; then
		_s=''
		wget --help 2>&1 | grep -q -- '--https-only' && _s='--https-only'
		if [ -n "$_o" ]; then wget -q $_s -T "$_t" -O "$_o" "$_u"
		else wget -q $_s -T "$_t" -O- "$_u"; fi
		return $?
	fi
	return 1
}

asset_urls() {
	jsonfilter -i "$1" -e '@.assets[*].browser_download_url' 2>/dev/null \
		| grep -E "/luci-theme-uniwrt[-_][^/]*\.$2\$" || true
}

asset_digest() {
	jsonfilter -i "$1" -e "@.assets[@.browser_download_url=\"$2\"].digest" 2>/dev/null | head -n1
}

if [ -f /etc/openwrt_release ]; then
	. /etc/openwrt_release 2>/dev/null || true
	ok "Detected: ${DISTRIB_DESCRIPTION:-OpenWrt}"
fi

if command -v apk >/dev/null 2>&1; then
	PM="apk"
	EXT="apk"
elif command -v opkg >/dev/null 2>&1; then
	PM="opkg"
	EXT="ipk"
else
	err "Neither apk nor opkg found — cannot install a package."
	exit 1
fi
ok "Package manager: $PM (preferring .$EXT)"

command -v jsonfilter >/dev/null 2>&1 || {
	err "jsonfilter not found — this installer expects an OpenWrt base image."
	exit 1
}
command -v sha256sum >/dev/null 2>&1 || {
	err "sha256sum not found — cannot verify the downloaded package."
	exit 1
}

if [ "$TAG" = "latest" ]; then
	API_URL="https://api.github.com/repos/$REPO/releases/latest"
else
	API_URL="https://api.github.com/repos/$REPO/releases/tags/$TAG"
fi

JSON="$TMP/release.json"
info "Resolving UniWRT release ($TAG) from $REPO..."
if ! fetch "$API_URL" 20 "$JSON" || [ ! -s "$JSON" ]; then
	err "Could not reach the GitHub release API."
	exit 1
fi

PKG_URL="$(asset_urls "$JSON" "$EXT" | head -n1)"
if [ -z "$PKG_URL" ]; then
	err "Could not find a luci-theme-uniwrt .$EXT asset for release '$TAG'."
	err "Check releases: https://github.com/$REPO/releases"
	exit 1
fi

PKG="$TMP/$(basename "$PKG_URL")"
info "Downloading $(basename "$PKG_URL")..."
if ! fetch "$PKG_URL" 600 "$PKG" || [ ! -s "$PKG" ]; then
	err "Package download failed."
	exit 1
fi

DIGEST="$(asset_digest "$JSON" "$PKG_URL")"
if [ -z "$DIGEST" ]; then
	err "No sha256 digest published for $(basename "$PKG_URL") — refusing to install."
	exit 1
fi
WANT="${DIGEST#sha256:}"
GOT="$(sha256sum "$PKG" | cut -d' ' -f1)"
if [ "$WANT" != "$GOT" ]; then
	err "Checksum mismatch for $(basename "$PKG_URL")."
	err "  expected $WANT"
	err "  got      $GOT"
	exit 1
fi
ok "sha256 verified: $(basename "$PKG_URL")"

info "Installing $(basename "$PKG_URL") with $PM..."
if [ "$PM" = "apk" ]; then
	apk add --allow-untrusted "$PKG"
else
	opkg install "$PKG"
fi

rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache 2>/dev/null || true

if [ -x /etc/init.d/rpcd ]; then
	/etc/init.d/rpcd reload >/dev/null 2>&1 || true
fi

if [ "$ACTIVATE" = 1 ]; then
	info "Activating UniWRT..."
	uci -q set luci.main.mediaurlbase=/luci-static/uniwrt
	uci -q commit luci
	if [ -x /etc/init.d/uhttpd ]; then
		/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
	fi
fi

printf '\n'
ok "luci-theme-uniwrt installed."
if [ "$ACTIVATE" = 1 ]; then
	info "UniWRT is now the active LuCI theme."
else
	info "Switch it later in System -> System -> Language and Style, or rerun with --activate."
fi
info "Hard-reload the page after switching (Ctrl+F5)."
