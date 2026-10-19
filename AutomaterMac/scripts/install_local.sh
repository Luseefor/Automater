#!/bin/zsh
# Install Tandem, retaining the established bundle ID, signing identity and data.
set -euo pipefail
ROOT="${0:A:h:h:h}"
APP="$ROOT/dist/Tandem.app"
DEST="/Applications/Tandem.app"
LEGACY="/Applications/Automater.app"
BUNDLE_ID="com.luseefor.automater"
[[ -d "$APP" ]] || { echo "Build first: AutomaterMac/scripts/bundle_app.sh" >&2; exit 2; }

osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
for _ in {1..30}; do
  if ! pgrep -f '/Applications/(Automater|Tandem).app/Contents/MacOS/Automater' >/dev/null 2>&1; then break; fi
  sleep 0.1
done
if pgrep -f '/Applications/(Automater|Tandem).app/Contents/MacOS/Automater' >/dev/null 2>&1; then
  echo "The app is still running; finish its save dialog, then run this installer again." >&2
  exit 1
fi

ditto "$APP" "$DEST"
xattr -cr "$DEST"
codesign --verify --deep --strict "$DEST"
# A reversible first-install rename avoids two installed copies with one bundle ID.
if [[ -d "$LEGACY" ]]; then
  LEGACY_BACKUP="$(mktemp -d /tmp/tandem-previous-install.XXXXXX)"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$LEGACY" 2>/dev/null || true
  mv "$LEGACY" "$LEGACY_BACKUP/Automater.app"
  echo "previous app retained at: $LEGACY_BACKUP/Automater.app"
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" 2>/dev/null || true
open -a "$DEST"
echo "installed and opened: $DEST"
