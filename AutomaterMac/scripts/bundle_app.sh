#!/bin/zsh
# Bundle Tandem.app from a release build, sign it, and optionally notarize.
#
# For a distributable build set DEVELOPER_ID_APPLICATION to the exact
# Developer ID Application identity and NOTARY_PROFILE to a keychain profile
# created with `xcrun notarytool store-credentials`. Then run with NOTARIZE=1.
#
# Signing happens in a clean staging dir outside the (possibly iCloud/FileProvider
# synced) repo: system-attached com.apple.provenance attributes make codesign
# refuse to sign in place ("resource fork, Finder information, or similar
# detritus"), and that attribute cannot be removed by xattr.
set -e -o pipefail
ROOT="${0:A:h:h:h}"            # AutomaterMac/scripts → AutomaterMac → repo
APPDIR="$ROOT/AutomaterMac"
BUILD="$APPDIR/.build/release"
DIST="$ROOT/dist"

swift build -c release --package-path "$APPDIR" 2>&1 | tail -1

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Tandem.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Tandem</string>
  <key>CFBundleDisplayName</key><string>Tandem</string>
  <key>CFBundleIdentifier</key><string>com.luseefor.automater</string>
  <key>CFBundleVersion</key><string>0.3.5</string>
  <key>CFBundleShortVersionString</key><string>0.3.5</string>
  <key>CFBundleExecutable</key><string>Automater</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>Automater</string>
  <key>NSAccessibilityUsageDescription</key>
    <string>Tandem clicks and types into other apps on your behalf.</string>
</dict></plist>
PLIST

cp "$BUILD/automater-app" "$APP/Contents/MacOS/Automater"
cp -X "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

if [ -f "$APPDIR/assets/Automater.icns" ]; then
  cp -X "$APPDIR/assets/Automater.icns" "$APP/Contents/Resources/"
else
  echo "note: no icns yet — run: scripts/make_icon.sh"
fi

# Strip any attributes that could trip the detritus check.
xattr -cr "$APP" 2>/dev/null || true
find "$APP" -name '._*' -delete 2>/dev/null || true

# Sign with a stable identity when one exists (keeps the TCC Accessibility
# grant valid across rebuilds); ad-hoc otherwise (grant resets each build).
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Automater Dev"/{print $2}' | sort | head -1)
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application:/{print $2; exit}')
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP"
else
  codesign --force -s - "$APP"
fi
codesign -v "$APP"
echo "signed: $APP (identity: ${IDENTITY:-ad-hoc})"

# Deliver the signed bundle into dist/ (signature survives the copy).
mkdir -p "$DIST"
rm -rf "$DIST/Tandem.app"
cp -R "$APP" "$DIST/Tandem.app"
# Finder can add metadata while copying a bundle into a user-visible folder.
# It is not part of the signed payload and causes strict verification to fail.
xattr -cr "$DIST/Tandem.app" 2>/dev/null || true
codesign -v "$DIST/Tandem.app"

cd "$DIST" && rm -f Tandem.zip && ditto -c -k --keepParent Tandem.app Tandem.zip
echo "zipped: $DIST/Tandem.zip ($(du -h Tandem.zip | cut -f1))"

if [ "${NOTARIZE:-0}" = "1" ]; then
  if [ -z "$IDENTITY" ] || [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "NOTARIZE=1 needs DEVELOPER_ID_APPLICATION (or an installed Developer ID identity) and NOTARY_PROFILE" >&2
    exit 2
  fi
  xcrun notarytool submit "$DIST/Tandem.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DIST/Tandem.app"
  xcrun stapler validate "$DIST/Tandem.app"
  spctl --assess --type execute --verbose=4 "$DIST/Tandem.app"
  rm -f "$DIST/Tandem.zip"
  ditto -c -k --keepParent "$DIST/Tandem.app" "$DIST/Tandem.zip"
  echo "notarized and stapled: $DIST/Tandem.app"
fi
