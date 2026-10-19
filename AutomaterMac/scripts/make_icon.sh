#!/bin/zsh
set -euo pipefail
ICON_ROOT="${0:A:h:h}"
ICON_BUILD="$(mktemp -d)"
trap 'rm -rf "$ICON_BUILD"' EXIT
swiftc -parse-as-library "$ICON_ROOT/Sources/automater-app/Branding.swift" "$ICON_ROOT/scripts/make_icon.swift" -o "$ICON_BUILD/make-icon"
"$ICON_BUILD/make-icon" "$ICON_ROOT/assets"
iconutil -c icns "$ICON_ROOT/assets/Automater.iconset" -o "$ICON_ROOT/assets/Automater.icns"
