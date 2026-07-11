#!/bin/bash
# Builds the sherpa-onnx static xcframework the app links against, from the
# official *no-tts* release build. Run once after cloning, before building.
#
# The no-tts variant matters for licensing: sherpa-onnx's full build embeds
# espeak-ng (GPLv3) for text-to-speech. VoiceYak only does speech-to-text,
# and shipping GPL code would conflict with the MIT license. Everything in
# the no-tts build is Apache-2.0 / MIT / BSD — see THIRD-PARTY-NOTICES.md.
set -euo pipefail

VERSION="1.13.4"
ARCHIVE="sherpa-onnx-v${VERSION}-osx-universal2-static-no-tts.tar.bz2"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/${ARCHIVE}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${REPO_ROOT}/sherpa-onnx.xcframework"
SLICE="${DEST}/macos-arm64_x86_64"

if [ -e "${SLICE}/libsherpa-onnx.a" ]; then
    echo "sherpa-onnx.xcframework already present — nothing to do."
    exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "Downloading sherpa-onnx v${VERSION} (static, no-tts)..."
curl -L --fail -o "${TMP_DIR}/${ARCHIVE}" "${URL}"

echo "Extracting..."
tar -xjf "${TMP_DIR}/${ARCHIVE}" -C "${TMP_DIR}"
SRC="${TMP_DIR}/sherpa-onnx-v${VERSION}-osx-universal2-static-no-tts"

echo "Merging static libraries..."
libtool -static -o "${TMP_DIR}/libsherpa-onnx.a" \
    "${SRC}/lib/libsherpa-onnx-c-api.a" \
    "${SRC}/lib/libsherpa-onnx-core.a" \
    "${SRC}/lib/libkaldi-decoder-core.a" \
    "${SRC}/lib/libkaldi-native-fbank-core.a" \
    "${SRC}/lib/libkissfft-float.a" \
    "${SRC}/lib/libsherpa-onnx-fst.a" \
    "${SRC}/lib/libsherpa-onnx-fstfar.a" \
    "${SRC}/lib/libsherpa-onnx-kaldifst-core.a" \
    "${SRC}/lib/libssentencepiece_core.a" \
    "${SRC}/lib/libonnxruntime.a" \
    2> >(grep -v "has no symbols" >&2 || true)

echo "Assembling xcframework..."
rm -rf "${DEST}"
mkdir -p "${SLICE}/Headers/sherpa-onnx/c-api"
mv "${TMP_DIR}/libsherpa-onnx.a" "${SLICE}/libsherpa-onnx.a"
cp "${SRC}/include/sherpa-onnx/c-api/c-api.h" "${SLICE}/Headers/sherpa-onnx/c-api/"
cp "${SRC}/include/sherpa-onnx/c-api/cxx-api.h" "${SLICE}/Headers/sherpa-onnx/c-api/" 2>/dev/null || true

cat > "${DEST}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>libsherpa-onnx.a</string>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64_x86_64</string>
			<key>LibraryPath</key>
			<string>libsherpa-onnx.a</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST

echo "Installed ${DEST}"
