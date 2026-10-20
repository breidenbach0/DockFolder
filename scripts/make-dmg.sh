#!/usr/bin/env bash
# Builds build/DockFolder.dmg for downloading: DockFolder.app next to a shortcut to Applications.
# Usage: scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/DockFolder"
ditto build/DockFolder.app "$STAGE/DockFolder/DockFolder.app"
ln -s /Applications "$STAGE/DockFolder/Applications"

rm -f build/DockFolder.dmg
hdiutil create -volname "DockFolder" -srcfolder "$STAGE/DockFolder" -format UDZO -quiet build/DockFolder.dmg
echo "Built build/DockFolder.dmg"
