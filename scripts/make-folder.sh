#!/usr/bin/env bash
# Creates a new Dock folder: a copy of the template app with its own name and bundle ID,
# so it gets its own Dock icon and its own saved list of apps.
#
# Usage: scripts/make-folder.sh "Design"          creates and opens it
#        scripts/make-folder.sh "Design" --pin    also pins it to the Dock (restarts the Dock)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <folder name> [--pin]" >&2
    exit 64
fi
NAME="$1"
PIN="${2:-}"

if [[ ! "$NAME" =~ ^[[:alnum:][:space:]._-]+$ ]]; then
    echo "Use letters, digits, spaces, dots, dashes or underscores in the folder name." >&2
    exit 64
fi
SLUG="$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')"
if [[ -z "$SLUG" ]]; then
    echo "The folder name needs at least one letter or digit." >&2
    exit 64
fi

TEMPLATE="build/DockFolder.app"
[[ -d "$TEMPLATE" ]] || scripts/build-app.sh

DEST_DIR="$HOME/Applications/Dock Folders"
APP="$DEST_DIR/$NAME.app"
if [[ -e "$APP" ]]; then
    echo "$APP already exists." >&2
    exit 1
fi

mkdir -p "$DEST_DIR"
cp -R "$TEMPLATE" "$APP"

# A custom icon written by a running template leaves an Icon\r file in the bundle root,
# which codesign refuses to sign. Each folder draws its own icon on first launch anyway.
rm -f "$APP/Icon"$'\r'
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true

PLIST="$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "dev.local.dockfolder.$SLUG" "$PLIST"
plutil -replace CFBundleName -string "$NAME" "$PLIST"
plutil -replace CFBundleDisplayName -string "$NAME" "$PLIST"
plutil -remove DockFolderRole "$PLIST" 2>/dev/null || true   # a copy is a folder, not the DockFolder window
codesign --force --sign - "$APP"

if [[ "$PIN" == "--pin" ]]; then
    defaults write com.apple.dock persistent-apps -array-add \
        "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$APP</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
    killall Dock
fi

open "$APP"
echo "Created $APP"
[[ "$PIN" == "--pin" ]] || echo "To keep it: right-click its Dock icon › Options › Keep in Dock."
