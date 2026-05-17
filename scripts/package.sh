#!/usr/bin/env bash
# Build a release .app bundle for DoubleFinder.
# Output: build/DoubleFinder.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="DoubleFinder"
BUNDLE_ID="com.doublefinder.app"
VERSION="${VERSION:-1.2}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MIN_OS="26.0"

BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "▶ Cleaning $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "▶ Release build"
cd "$ROOT"
swift build -c release --arch arm64

BIN_PATH="$ROOT/.build/release/$APP_NAME"
if [ ! -x "$BIN_PATH" ]; then
    echo "✗ Release binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "▶ Copying executable"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

echo "▶ Re-wrapping SwiftPM resource bundles into proper macOS bundle layout"
shopt -s nullglob
for bundle in "$ROOT/.build/release/"*.bundle; do
    name="$(basename "$bundle" .bundle)"
    dest="$MACOS_DIR/$name.bundle"
    rm -rf "$dest"
    mkdir -p "$dest/Contents/Resources"
    cp -R "$bundle"/* "$dest/Contents/Resources/"
    cat > "$dest/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID.$name</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$name</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
</dict>
</plist>
EOF
done
shopt -u nullglob

echo "▶ Installing icon"
cp "$ROOT/Sources/DoubleFinder/Resources/DoubleFinder.icns" "$RESOURCES_DIR/AppIcon.icns"

echo "▶ Writing Info.plist"
cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_OS</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>DoubleFinder needs access to your Desktop to browse files.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>DoubleFinder needs access to your Documents to browse files.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>DoubleFinder needs access to your Downloads to browse files.</string>
</dict>
</plist>
EOF

echo "▶ PkgInfo"
printf "APPL????" > "$CONTENTS/PkgInfo"

echo "▶ Ad-hoc code signing"
codesign --force --deep --sign - "$APP_DIR"

echo
echo "✓ Built $APP_DIR"
du -sh "$APP_DIR"

# -----------------------------------------------------------------------------
# Build a distributable .dmg
# -----------------------------------------------------------------------------
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
STAGING_DIR="$BUILD_DIR/dmg-staging"

echo
echo "▶ Building $DMG_NAME"

# Fresh staging directory: the .app plus an /Applications symlink so users get
# the standard "drag onto Applications to install" experience when mounting.
rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# UDZO = zlib-compressed read-only image. Quiet flag keeps output tidy on success.
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -quiet \
    "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "✓ Built $DMG_PATH"
du -sh "$DMG_PATH"
echo
echo "Run with:    open \"$APP_DIR\""
echo "Install via: mv \"$APP_DIR\" /Applications/"
echo "Share via:   $DMG_PATH"
