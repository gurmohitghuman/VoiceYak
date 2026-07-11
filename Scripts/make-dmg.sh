#!/bin/bash
# Builds a Release VoiceYak.app and packages it into a DMG.
#
# By default the app is signed with the project's normal signing identity
# (Apple Development) — fine for your own Macs. For public distribution,
# pass a Developer ID identity and notarize the result:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Scripts/make-dmg.sh
#
# OUTPUT_DIR overrides where the .dmg lands (default: dist/).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${REPO_ROOT}/dist"
BUILD="${DIST}/build"
OUTPUT_DIR="${OUTPUT_DIR:-${DIST}}"
VOLUME_NAME="VoiceYak"

if [ ! -e "${REPO_ROOT}/sherpa-onnx.xcframework/macos-arm64_x86_64/libsherpa-onnx.a" ]; then
    "${REPO_ROOT}/Scripts/fetch-sherpa-onnx.sh"
fi

mkdir -p "${DIST}" "${OUTPUT_DIR}"
rm -rf "${BUILD}"

echo "Building Release..."
xcodebuild -project "${REPO_ROOT}/VoiceYak.xcodeproj" \
    -scheme VoiceYak \
    -configuration Release \
    -derivedDataPath "${BUILD}" \
    ${SIGN_IDENTITY:+CODE_SIGN_IDENTITY="${SIGN_IDENTITY}"} \
    -quiet \
    build

APP="${BUILD}/Build/Products/Release/VoiceYak.app"
[ -d "${APP}" ] || { echo "Build failed — ${APP} not found" >&2; exit 1; }

VERSION="$(defaults read "${APP}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo 1.0)"
DMG="${OUTPUT_DIR}/VoiceYak-${VERSION}.dmg"

echo "Packaging ${DMG}..."
STAGING="$(mktemp -d)"
RW_DMG="${DIST}/.voiceyak-rw.dmg"
trap 'rm -rf "${STAGING}" "${RW_DMG}"' EXIT

cp -R "${APP}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

# Volume icon, taken from the app itself
if [ -f "${APP}/Contents/Resources/AppIcon.icns" ]; then
    cp "${APP}/Contents/Resources/AppIcon.icns" "${STAGING}/.VolumeIcon.icns"
fi

# Build read-write first so the window can be dressed, then compress.
rm -f "${RW_DMG}" "${DMG}"
hdiutil create -volname "${VOLUME_NAME}" -srcfolder "${STAGING}" -ov -format UDRW -quiet "${RW_DMG}"

MOUNT_POINT="/Volumes/${VOLUME_NAME}"
hdiutil attach "${RW_DMG}" -mountpoint "${MOUNT_POINT}" -nobrowse -quiet

# Flag the volume as having a custom icon
if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "${MOUNT_POINT}" || true
fi

# Arrange the window: app left, Applications right. Best-effort — Finder
# automation may be denied in headless environments.
osascript <<EOF >/dev/null 2>&1 || echo "  (window layout skipped — Finder automation unavailable)"
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 780, 470}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 104
        set text size of viewOptions to 13
        set position of item "VoiceYak.app" of container window to {150, 160}
        set position of item "Applications" of container window to {430, 160}
        close
    end tell
end tell
EOF
sync

hdiutil detach "${MOUNT_POINT}" -quiet
hdiutil convert "${RW_DMG}" -format UDZO -o "${DMG}" -quiet
hdiutil verify -quiet "${DMG}"

echo "Done: ${DMG}"
echo
echo "Install: open the DMG, drag VoiceYak into Applications."
if [ -z "${SIGN_IDENTITY:-}" ]; then
    echo "Note: not Developer ID-signed — other Macs will warn on open."
fi
