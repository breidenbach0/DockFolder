#!/usr/bin/env bash
# Builds build/DockFolder.dmg for downloading: DockFolder.app next to a shortcut to Applications.
# Also builds build/DockFolder.zip, the app on its own, which DockFolder's updater installs, and
# signs it into build/DockFolder.zip.sig with the update key in your Keychain (macOS asks you to
# allow that). Attach all three to a release.
# Usage: scripts/make-dmg.sh
#        UNSIGNED=1 scripts/make-dmg.sh     no signature, for builds that won't be released
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/DockFolder"
# Only owner-writable files, and no extended attributes, quarantine or ACLs.
chmod -R go-w build/DockFolder.app
ditto --norsrc --noextattr --noqtn --noacl build/DockFolder.app "$STAGE/DockFolder/DockFolder.app"
ln -s /Applications "$STAGE/DockFolder/Applications"

rm -f build/DockFolder.dmg
hdiutil create -volname "DockFolder" -srcfolder "$STAGE/DockFolder" -format UDZO -quiet build/DockFolder.dmg
echo "Built build/DockFolder.dmg"

rm -f build/DockFolder.zip
ditto -c -k --norsrc --keepParent build/DockFolder.app build/DockFolder.zip
echo "Built build/DockFolder.zip"

# DockFolder's updater installs nothing without this signature.
rm -f build/DockFolder.zip.sig
if [[ "${UNSIGNED:-0}" != 1 ]]; then
    swiftc -O -suppress-warnings scripts/sign-update.swift -o build/sign-update
    build/sign-update build/DockFolder.zip > build/DockFolder.zip.sig.tmp
    mv build/DockFolder.zip.sig.tmp build/DockFolder.zip.sig
    echo "Signed build/DockFolder.zip"
fi
