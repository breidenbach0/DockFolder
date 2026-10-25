#!/usr/bin/env bash
# Builds build/DockFolder.app. Opened directly, it's the window for making and changing
# folders; it's also the template every folder is copied from.
# Usage: scripts/build-app.sh            (release build)
#        CONFIG=debug scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
NAME="${NAME:-DockFolder}"
BUNDLE_ID="${BUNDLE_ID:-dev.local.dockfolder}"

MIN_MACOS="13.0"   # keep in step with platforms in Package.swift
APP="build/DockFolder.app"

# One app for Apple silicon and Intel.
BUILD=(swift build -c "$CONFIG" --arch arm64 --arch x86_64)
"${BUILD[@]}"
BIN_DIR="$("${BUILD[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# SwiftPM records the deployment target as the SDK the app was built with, and macOS then draws
# its windows in the pre-Tahoe style (no glass toolbar or sidebar). Record the SDK actually used.
xcrun vtool -set-build-version macos "$MIN_MACOS" "$(xcrun --show-sdk-version)" -replace \
    -output "$APP/Contents/MacOS/DockFolder" "$BIN_DIR/DockFolder"

# The app draws its own icon, the same glass folder it makes.
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN_DIR/DockFolder" --write-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# Folders keep this stamp, so the DockFolder window can offer to update ones from older builds.
BUILD_STAMP="$(shasum -a 256 "$BIN_DIR/DockFolder" | cut -c1-16)"

# CFBundleDocumentTypes lets the user drop .app bundles onto the folder's Dock icon.
# DockFolderRole makes this copy the DockFolder window; folders are copies without it.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DockFolder</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${NAME}</string>
    <key>CFBundleDisplayName</key><string>${NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.6.0</string>
    <key>CFBundleVersion</key><string>7</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>DockFolderRole</key><string>manager</string>
    <key>DockFolderBuild</key><string>${BUILD_STAMP}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>dev.local.dockfolder.dock-app</string>
            <key>UTTypeDescription</key><string>App being moved from the Dock into a folder</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Application</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>com.apple.application-bundle</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally on Apple silicon. Use a Developer ID to distribute.
codesign --force --sign - "$APP"
echo "Built $APP"
