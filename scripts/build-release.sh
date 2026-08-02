#!/usr/bin/env bash
#
# Build, sign, notarize and package yap for distribution: a menu-bar yap.app
# inside a .dmg. Everything signs with a single Developer ID Application
# certificate — no Developer ID Installer cert, which is why this ships an
# .app/.dmg rather than a .pkg.
#
# A bare Mach-O binary cannot be stapled, so even though yap is a CLI first,
# distribution goes through a bundle. The CLI still works:
#   /Applications/yap.app/Contents/MacOS/yap
#
# The same script runs locally and in CI.
#
# Configuration, all via environment:
#   VERSION          release version, e.g. 0.1.0              (default: 0.1.0)
#   APP_IDENTITY     "Developer ID Application: NAME (TEAMID)"
#   NOTARY_PROFILE   notarytool keychain profile (enables notarize + staple)
#   SKIP_NOTARIZE=1  build and sign, but do not notarize (local testing)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.1.0}"
APP_IDENTITY="${APP_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

BUILD_BIN="$ROOT/.build/arm64-apple-macosx/release/yap"
ENTITLEMENTS="$ROOT/packaging/yap.entitlements"
PLIST_TEMPLATE="$ROOT/packaging/Info.plist"
ICON="$ROOT/packaging/yap.icns"
DIST="$ROOT/dist"
APP="$DIST/yap.app"
DMG="$DIST/yap-$VERSION.dmg"
DMG_STAGE="$DIST/dmg"

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

if [[ -z "$APP_IDENTITY" ]]; then
  echo "APP_IDENTITY is unset." >&2
  echo "Set it to your Developer ID Application identity, e.g.:" >&2
  echo '  APP_IDENTITY="Developer ID Application: Your Name (TEAMID)"' >&2
  echo "List what you have with: security find-identity -v -p codesigning" >&2
  exit 1
fi

step "Building release binary (arm64)"
swift build -c release --arch arm64

step "Assembling yap.app"
rm -rf "$APP" "$DMG" "$DMG_STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed "s/@VERSION@/$VERSION/g" "$PLIST_TEMPLATE" > "$APP/Contents/Info.plist"
cp "$BUILD_BIN" "$APP/Contents/MacOS/yap"
[[ -f "$ICON" ]] && cp "$ICON" "$APP/Contents/Resources/yap.icns"
xattr -cr "$APP"

step "Codesigning app (hardened runtime + entitlements)"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$APP_IDENTITY" \
  "$APP"
codesign --verify --strict --verbose=2 "$APP"

notarize() {
  local artifact="$1" label="$2"
  if [[ "${SKIP_NOTARIZE:-}" == "1" || -z "$NOTARY_PROFILE" ]]; then
    step "Skipping $label notarization (SKIP_NOTARIZE set or NOTARY_PROFILE empty)"
    return
  fi
  step "Notarizing $label"
  if [[ "$artifact" == *.app ]]; then
    ditto -c -k --keepParent "$artifact" "$DIST/notarize.zip"
    xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$DIST/notarize.zip"
  else
    xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait
  fi
  step "Stapling $label"
  xcrun stapler staple "$artifact"
}

notarize "$APP" "app"

step "Building .dmg"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "yap $VERSION" -srcfolder "$DMG_STAGE" \
  -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_STAGE"

step "Codesigning .dmg"
codesign --force --timestamp --sign "$APP_IDENTITY" "$DMG"

notarize "$DMG" "dmg"

if [[ "${SKIP_NOTARIZE:-}" != "1" && -n "$NOTARY_PROFILE" ]]; then
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" || true
else
  echo
  echo "WARNING: not notarized — local testing only. Gatekeeper will complain." >&2
fi

step "Done"
echo "App: $APP"
echo "DMG: $DMG"
