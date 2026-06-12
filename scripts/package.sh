#!/usr/bin/env bash
# Build a release .app bundle for DoubleFinder.
# Output: build/DoubleFinder.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="DoubleFinder"
BUNDLE_ID="com.doublefinder.app"
VERSION="${VERSION:-1.6}"
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

# Universal binary by default: macOS 26 still runs on Intel Macs, and an
# arm64-only slice can't launch there at all. Override with ARCHS="arm64".
ARCH_FLAGS=()
for arch in ${ARCHS:-arm64 x86_64}; do
    ARCH_FLAGS+=(--arch "$arch")
done

echo "▶ Release build (${ARCHS:-arm64 x86_64})"
cd "$ROOT"
swift build -c release "${ARCH_FLAGS[@]}"

# With multiple --arch flags SwiftPM writes to .build/apple/Products/Release,
# not .build/release — always resolve the real output directory.
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"
BIN_PATH="$BIN_DIR/$APP_NAME"
if [ ! -x "$BIN_PATH" ]; then
    echo "✗ Release binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "▶ Copying executable"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# Multi-arch builds go through the Xcode build system, whose generated
# Bundle.module accessor resolves resource bundles via Bundle.main.resourceURL
# (Contents/Resources) and whose output is already a proper macOS bundle —
# copy it there verbatim. Single-arch SwiftPM-native builds instead emit a
# flat bundle whose accessor hardcodes an absolute path into .build/, which
# only resolves on the build machine — refuse to package those.
echo "▶ Copying SwiftPM resource bundles into Contents/Resources"
shopt -s nullglob
for bundle in "$BIN_DIR/"*.bundle; do
    name="$(basename "$bundle")"
    if [ ! -f "$bundle/Contents/Info.plist" ]; then
        echo "✗ $name has the flat SwiftPM-native layout; the binary would look" >&2
        echo "  for resources in $ROOT/.build and crash on other machines." >&2
        echo "  Build with at least two --arch flags (ARCHS=\"arm64 x86_64\")." >&2
        exit 1
    fi
    rm -rf "$RESOURCES_DIR/$name"
    cp -R "$bundle" "$RESOURCES_DIR/$name"
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

# -----------------------------------------------------------------------------
# Code signing.
#
# An ad-hoc signature (--sign -) only runs on machines where the app never
# acquires the quarantine attribute — i.e. the build machine. On every other
# Mac, Gatekeeper assesses the downloaded app, finds no Developer ID and no
# notarization, and refuses to launch it. Distributing to other machines
# requires a "Developer ID Application" certificate (paid Apple Developer
# account) plus notarization.
#
# Set SIGN_IDENTITY to a signing identity (or let the script auto-detect a
# Developer ID Application certificate in the keychain). Without one, the
# script falls back to ad-hoc and the result is local-use only.
# -----------------------------------------------------------------------------
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"

# The resource bundles contain no code, so the app-level signature seals them
# under Contents/Resources — no nested signing needed. Notarization requires
# the hardened runtime and a secure timestamp.
if [ -n "$SIGN_IDENTITY" ]; then
    echo "▶ Code signing with: $SIGN_IDENTITY"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    echo "▶ Ad-hoc code signing (no Developer ID identity found)"
    echo "  ⚠ This app will be blocked by Gatekeeper on other machines."
    codesign --force --sign - "$APP_DIR"
fi

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

# Notarize the DMG so Gatekeeper accepts it on other machines. Requires a
# Developer ID signature plus stored notarytool credentials:
#   xcrun notarytool store-credentials "AC_PASSWORD" --apple-id ... --team-id ... --password ...
# then run with NOTARY_PROFILE=AC_PASSWORD. Notarizing the DMG generates
# tickets for the app inside it; stapling the DMG attaches the ticket for
# offline verification.
if [ -n "$SIGN_IDENTITY" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "▶ Signing and notarizing $DMG_NAME"
    codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
elif [ -n "$SIGN_IDENTITY" ]; then
    echo "⚠ DMG signed but NOT notarized (set NOTARY_PROFILE to notarize)."
    echo "  Gatekeeper may still block it on other machines."
    codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"
else
    echo "⚠ DMG is ad-hoc signed only — Gatekeeper will block the app on other"
    echo "  machines. Recipients must clear quarantine after copying the app:"
    echo "      xattr -d com.apple.quarantine /Applications/$APP_NAME.app"
    echo "  For normal distribution, sign with a Developer ID certificate and"
    echo "  notarize (see comments in this script)."
fi

echo "✓ Built $DMG_PATH"
du -sh "$DMG_PATH"
echo
echo "Run with:    open \"$APP_DIR\""
echo "Install via: mv \"$APP_DIR\" /Applications/"
echo "Share via:   $DMG_PATH"
