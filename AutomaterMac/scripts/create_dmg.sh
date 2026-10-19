#!/bin/zsh
# Build an automation-themed drag-to-Applications DMG.
set -euo pipefail

ROOT="${0:A:h:h:h}"
DIST="$ROOT/dist"
APP="$DIST/Tandem.app"
OUT="$DIST/Tandem.dmg"
RW="$DIST/Tandem-rw.dmg"
STAGE="$(mktemp -d)"
VOLUME="Tandem"
trap 'rm -rf "$STAGE"' EXIT

[[ -d "$APP" ]] || { echo "Build the app first: AutomaterMac/scripts/bundle_app.sh" >&2; exit 2; }
rm -f "$OUT" "$RW"
mkdir -p "$STAGE/.background"

swift "$ROOT/AutomaterMac/scripts/make_dmg_background.swift" "$STAGE/.background/background.png"
# Newer hdiutil versions accept -format only when copying from a folder or
# device.  A blank UDIF is already read/write and can later be converted to
# the compressed distribution image below.
hdiutil create -size 40m -fs HFS+ -volname "$VOLUME" -type UDIF "$RW" >/dev/null
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/\/Volumes\// {print $3; exit}')"
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rm -rf "$STAGE"' EXIT
# Finder metadata is not signed; ensure it cannot be copied from the working
# distribution bundle into the install image.
xattr -cr "$APP" 2>/dev/null || true
cp -R "$APP" "$MOUNT/Tandem.app"
ln -s /Applications "$MOUNT/Applications"
mkdir -p "$MOUNT/.background"
cp "$STAGE/.background/background.png" "$MOUNT/.background/background.png"
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 780, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set background picture of viewOptions to file ".background:background.png"
    set position of item "Tandem.app" to {190, 215}
    set position of item "Applications" to {490, 215}
    close
    open
    update without registering applications
  end tell
end tell
APPLESCRIPT
# Finder can tag the app while laying out the window.  Remove those tags from
# the mounted copy before converting it into the final read-only image.
xattr -cr "$MOUNT/Tandem.app" 2>/dev/null || true
sync
hdiutil detach "$MOUNT" -quiet
hdiutil convert "$RW" -format UDZO -o "$OUT" >/dev/null
rm -f "$RW"
# Finder's disk-window customization may tag the source app after the image
# has been created.  Keep the release bundle clean for strict verification;
# the already-copied DMG contents are unaffected.
xattr -cr "$APP" 2>/dev/null || true
echo "created $OUT"
