#!/usr/bin/env bash
# Netalico build of Cap for Apple Silicon, run on a Mac (mac-server).
#   scripts/netalico-build-macos.sh compile   # unsigned compile, the slow part
#   scripts/netalico-build-macos.sh package   # sign, notarise, updater signature
#   scripts/netalico-build-macos.sh all
# package needs: the Developer ID cert in the login keychain, a notarytool
# keychain profile (NOTARY_PROFILE, default netalico-notary), and the updater
# key via TAURI_SIGNING_PRIVATE_KEY(_PASSWORD) or 1Password (`op`).
set -euo pipefail

STAGE="${1:-all}"
TARGET="aarch64-apple-darwin"
SERVER_URL="${CAP_SERVER_URL:-https://watch.netalico.com}"
SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-Developer ID Application: Netalico, LLC. (67QJ26MRRW)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-netalico-notary}"
OP_ITEM="op://Netalico Team/Cap desktop updater signing key (Netalico fork)"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$HOME/.bun/bin:$PATH"
export RUST_TARGET_TRIPLE="$TARGET"
BUNDLE="apps/desktop-gpui/target/$TARGET/release/bundle"
VERSION="$(sed -n 's/^version = "\(.*\)"$/\1/p' apps/desktop-gpui/Cargo.toml | head -1)"
OUT="$REPO_ROOT/netalico-dist/$VERSION"

write_env() {
	{
		echo "appVersion=$VERSION"
		echo "VITE_ENVIRONMENT=production"
		echo "NEXT_PUBLIC_WEB_URL=$SERVER_URL"
		echo "NEXTAUTH_URL=$SERVER_URL"
		echo "VITE_SERVER_URL=$SERVER_URL"
		echo "RUST_TARGET_TRIPLE=$TARGET"
	} >.env
}

compile() {
	write_env
	bun install --frozen-lockfile
	bun run cap-setup
	CARGO_PROFILE_RELEASE_DEBUG=0 CARGO_PROFILE_RELEASE_STRIP=symbols \
		./scripts/build-desktop-binaries.sh "$TARGET"
	CI=false node scripts/bundle-gpui.mjs "$TARGET" --no-bundle
}

load_updater_key() {
	if [[ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]]; then
		TAURI_SIGNING_PRIVATE_KEY="$(op read "$OP_ITEM/private key")"
		TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$(op read "$OP_ITEM/password")"
	fi
	export TAURI_SIGNING_PRIVATE_KEY TAURI_SIGNING_PRIVATE_KEY_PASSWORD
}

package() {
	write_env
	security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY" || {
		echo "error: '$SIGNING_IDENTITY' is not in the keychain" >&2
		exit 1
	}
	xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null || {
		echo "error: notarytool profile '$NOTARY_PROFILE' missing; run xcrun notarytool store-credentials" >&2
		exit 1
	}
	load_updater_key
	export APPLE_SIGNING_IDENTITY="$SIGNING_IDENTITY"
	CI=false node scripts/bundle-gpui.mjs "$TARGET" --skip-build --bundles app,dmg
	node scripts/finalize-macos-packages.mjs "$BUNDLE"

	local dmg
	dmg="$(ls "$BUNDLE"/dmg/*.dmg | head -1)"
	xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
	xcrun stapler staple "$dmg"
	spctl --assess --type open --context context:primary-signature -v "$dmg"

	mkdir -p "$OUT"
	cp "$dmg" "$OUT/"
	cp "$BUNDLE"/macos/*.app.tar.gz "$BUNDLE"/macos/*.app.tar.gz.sig "$OUT/" 2>/dev/null || true
	echo "Built Cap $VERSION -> $OUT"
	ls -la "$OUT"
}

case "$STAGE" in
compile) compile ;;
package) package ;;
all) compile && package ;;
*)
	echo "usage: $0 compile|package|all" >&2
	exit 2
	;;
esac
