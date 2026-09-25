#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ApexTerm.app"
BUILD_DIR=".build"
APP_DIR="${BUILD_DIR}/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
VERSION="${1:-1.2.0}"
DIST_ARCHIVE="${BUILD_DIR}/ApexTerm-v${VERSION}-macos-arm64.tar.gz"
DIST_DMG="${BUILD_DIR}/ApexTerm-v${VERSION}-macos-arm64.dmg"

echo "🧹 [Clean] Removing all previous local build artifacts and archives..."
rm -rf "${APP_DIR}" "${BUILD_DIR}"/*.dmg "${BUILD_DIR}"/*.tar.gz "${BUILD_DIR}"/arm64-apple-macosx/release/ApexTerm* /tmp/apexterm_* 2>/dev/null || true

echo "🧪 [Pre-Release Quality Gate] Running full automated test suite (58+ test cases)..."
if ! swift test; then
    echo "❌ [FATAL ERROR] Automated test suite failed! Release build aborted to prevent shipping broken binaries."
    exit 1
fi
echo "✅ [Pre-Release Quality Gate] 100% of test suites passed successfully!"

echo "⚡ Building ApexTerm Release binary for Apple Silicon (arm64)..."
swift build -c release

echo "📦 Packaging ${APP_NAME} bundle..."
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "Resources/ApexTerm.icns" "${RESOURCES_DIR}/ApexTerm.icns"

# Copy release binary
RELEASE_BIN=""
if [ -f ".build/out/Products/Release/ApexTerm" ]; then
    RELEASE_BIN=".build/out/Products/Release/ApexTerm"
elif [ -f ".build/arm64-apple-macosx/release/ApexTerm" ]; then
    RELEASE_BIN=".build/arm64-apple-macosx/release/ApexTerm"
else
    RELEASE_BIN=$(find .build -type f -perm +111 -name "ApexTerm" | grep -i "release" | head -1)
fi

echo "📋 Using Release binary: ${RELEASE_BIN}"
cp "${RELEASE_BIN}" "${MACOS_DIR}/ApexTerm"
chmod +x "${MACOS_DIR}/ApexTerm"

if [ -f "/opt/homebrew/bin/sshpass" ]; then
    echo "📦 Bundling standalone arm64 sshpass helper into ${MACOS_DIR}/sshpass..."
    cp "/opt/homebrew/bin/sshpass" "${MACOS_DIR}/sshpass"
    chmod +x "${MACOS_DIR}/sshpass"
fi

# Create standard Info.plist
cat << EOF > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ApexTerm</string>
    <key>CFBundleIdentifier</key>
    <string>com.apexterm.app</string>
    <key>CFBundleName</key>
    <string>ApexTerm</string>
    <key>CFBundleDisplayName</key>
    <string>ApexTerm</string>
    <key>CFBundleIconFile</key>
    <string>ApexTerm</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>120</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSRequiresAquaSystemAppearance</key>
    <false/>
</dict>
</plist>
EOF

# Code Signing
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
if [ -z "${SIGNING_IDENTITY}" ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application:" | head -1 | awk -F '"' '{print $2}' || true)
fi
if [ -z "${SIGNING_IDENTITY}" ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development:" | head -1 | awk -F '"' '{print $2}' || true)
fi

if [ -n "${SIGNING_IDENTITY}" ]; then
    echo "🔏 Signing with certificate: ${SIGNING_IDENTITY}..."
    if [ -f "${MACOS_DIR}/sshpass" ]; then
        codesign --force --sign "${SIGNING_IDENTITY}" --options runtime --timestamp=none "${MACOS_DIR}/sshpass"
    fi
    codesign --force --deep --sign "${SIGNING_IDENTITY}" --options runtime --timestamp=none "${APP_DIR}"
else
    echo "⚠️ No certificates found, using ad-hoc signature..."
    codesign --force --deep --sign - "${APP_DIR}"
fi

# Verify signature
echo "🔍 Verifying code signature..."
codesign -vvv --deep --strict "${APP_DIR}"

# Create Distribution Archive
echo "📦 Creating compressed archive: ${DIST_ARCHIVE}..."
tar -czf "${DIST_ARCHIVE}" -C "${BUILD_DIR}" "${APP_NAME}"

# Create Distribution DMG
if command -v hdiutil >/dev/null 2>&1; then
    echo "💿 Creating Apple DMG disk image: ${DIST_DMG}..."
    TMP_DMG_DIR=$(mktemp -d /tmp/apexterm_dmg.XXXXXX)
    cp -R "${APP_DIR}" "${TMP_DMG_DIR}/"
    ln -s /Applications "${TMP_DMG_DIR}/Applications"
    hdiutil create -volname "ApexTerm" -srcfolder "${TMP_DMG_DIR}" -ov -format UDZO "${DIST_DMG}" -quiet
    rm -rf "${TMP_DMG_DIR}"
fi

if [ -d "/Applications" ]; then
    echo "📲 Updating local /Applications/ApexTerm.app..."
    rm -rf "/Applications/ApexTerm.app"
    cp -R "${APP_DIR}" "/Applications/ApexTerm.app"
fi

echo "✅ Build & Signed Packaging complete!"
echo "📍 Application: ${APP_DIR} (and /Applications/ApexTerm.app)"
echo "📍 Tarball:     ${DIST_ARCHIVE}"
if [ -f "${DIST_DMG}" ]; then
    echo "📍 Disk Image:  ${DIST_DMG}"
fi
