#!/usr/bin/env bash
set -euo pipefail

if [ "${APEX_UI_ACCEPTANCE_PREFLIGHT_ONLY:-0}" = "1" ]; then
    echo 'Release requires full UI acceptance; preflight-only packaging is forbidden.' >&2
    exit 1
fi

APP_NAME="ApexTerm.app"
BUILD_DIR=".build"
APP_DIR="${BUILD_DIR}/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

VERSION="${1:-1.2.0}"
DATE_PREFIX=$(date +%Y%m%d)
BUILD_NUMBER="${2:-${DATE_PREFIX}01}"
DIST_ARCHIVE="${BUILD_DIR}/ApexTerm-v${VERSION}-macos-arm64.tar.gz"
DIST_DMG="${BUILD_DIR}/ApexTerm-v${VERSION}-macos-arm64.dmg"
SHA_FILE="${BUILD_DIR}/SHA256SUMS.txt"

if [ -n "$(git status --porcelain)" ]; then
    echo "❌ Release requires a clean committed working tree."
    exit 1
fi
if [ "$(git branch --show-current)" != "master" ] && [ "$(git branch --show-current)" != "main" ]; then
    echo "❌ Release must be built from master or main."
    exit 1
fi
bash scripts/test_ui_acceptance.sh --preflight-only
# Keep only the current build outputs; old packages must not accumulate on disk.
python3 scripts/prune_build_artifacts.py

echo "🧪 [Pre-Release Quality Gate] Executing Tart VM acceptance and automated test gate..."
if ! ./scripts/test_vm_acceptance.sh; then
    echo "❌ [FATAL ERROR] Pre-release quality gate failed! Release build aborted to prevent shipping broken binaries."
    exit 1
fi
echo "✅ [Pre-Release Quality Gate] 100% of quality gate criteria satisfied!"

echo "⚡ Building ApexTerm Release binary for Apple Silicon (arm64)..."
swift build -c release --jobs 2
echo "🧪 Running mandatory window UI acceptance..."
bash scripts/test_ui_acceptance.sh

echo "📦 Packaging ${APP_NAME} bundle (v${VERSION} Build ${BUILD_NUMBER})..."
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
# Remove linker debug paths before security scanning and Developer ID signing.
/usr/bin/strip -S "${MACOS_DIR}/ApexTerm"
chmod +x "${MACOS_DIR}/ApexTerm"

if [ -f "/opt/homebrew/bin/sshpass" ]; then
    echo "📦 Bundling standalone arm64 sshpass helper into ${MACOS_DIR}/sshpass..."
    cp "/opt/homebrew/bin/sshpass" "${MACOS_DIR}/sshpass"
    chmod +x "${MACOS_DIR}/sshpass"
fi

# Create standard Info.plist aligned with AetherRoute standards
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
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>连接你选择的局域网 SSH 服务器，并进行 SFTP 文件传输和系统监控。</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSRequiresAquaSystemAppearance</key>
    <false/>
</dict>
</plist>
EOF

# 🛡️ Zero-Bundle Security Verification (AetherRoute SOP)
echo "🛡️ [Security Scan] Scanning app bundle for forbidden private credentials or sessions..."
LEAKS=$(find "${APP_DIR}" -type f \( -name "*.pem" -o -name "*.key" -o -name "*id_rsa*" -o -name "*sessions*.json" \) 2>/dev/null || true)
if [ -n "${LEAKS}" ]; then
    echo "❌ [SECURITY FATAL] Bundle contains forbidden private keys or session files:"
    echo "${LEAKS}"
    exit 1
fi
python3 scripts/verify_bundle_security.py "${APP_DIR}"
echo "✅ [Security Scan] Clean! No private keys or developer credentials leaked."

# Code Signing
SIGNING_IDENTITY="Developer ID Application: YanNan Chen (5984KQD4D7)"
if ! security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY"; then
    echo "❌ Required Developer ID certificate unavailable."
    exit 1
fi
sign_with_retry() {
    local target="$1"
    local deep="${2:-}"
    for i in 1 2 3; do
        if [ "$deep" = "--deep" ]; then
            if codesign --force --deep --sign "${SIGNING_IDENTITY}" --options runtime --timestamp "${target}"; then
                return 0
            fi
        else
            if codesign --force --sign "${SIGNING_IDENTITY}" --options runtime --timestamp "${target}"; then
                return 0
            fi
        fi
        echo "⚠️ [Code Signing] Timestamp service glitch (attempt $i/3), retrying in 2s..."
        sleep 2
    done
    return 1
}

if [ -f "${MACOS_DIR}/sshpass" ]; then
    sign_with_retry "${MACOS_DIR}/sshpass"
fi
sign_with_retry "${APP_DIR}" --deep

# Verify signature
echo "🔍 Verifying code signature..."
codesign -vvv --deep --strict "${APP_DIR}"

# Notarize and staple the app before producing either distribution format.
NOTARY_PROFILE="${NOTARY_PROFILE:-AetherRoute-Notary}"
NOTARY_ZIP="${BUILD_DIR}/ApexTerm-notarization.zip"
ditto -c -k --keepParent "${APP_DIR}" "${NOTARY_ZIP}"
xcrun notarytool submit "${NOTARY_ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait --output-format json > "${BUILD_DIR}/notarization-app.json"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted", "Apple notarization rejected"' "${BUILD_DIR}/notarization-app.json"
xcrun stapler staple "${APP_DIR}"
xcrun stapler validate "${APP_DIR}"
spctl --assess --type execute --verbose=2 "${APP_DIR}"
tar --uid 0 --gid 0 --uname root --gname wheel -czf "${DIST_ARCHIVE}" -C "${BUILD_DIR}" "${APP_NAME}"

# Create Distribution DMG
if command -v hdiutil >/dev/null 2>&1; then
    echo "💿 Creating Apple DMG disk image: ${DIST_DMG}..."
    TMP_DMG_DIR=$(mktemp -d /tmp/apexterm_dmg.XXXXXX)
    cp -R "${APP_DIR}" "${TMP_DMG_DIR}/"
    ln -s /Applications "${TMP_DMG_DIR}/Applications"
    hdiutil create -volname "ApexTerm" -fs HFS+ -srcfolder "${TMP_DMG_DIR}" -ov -format UDZO "${DIST_DMG}" -quiet
    rm -rf "${TMP_DMG_DIR}"
fi

codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${DIST_DMG}"
xcrun notarytool submit "${DIST_DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait --output-format json > "${BUILD_DIR}/notarization-dmg.json"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted", "DMG notarization rejected"' "${BUILD_DIR}/notarization-dmg.json"
xcrun stapler staple "${DIST_DMG}"
xcrun stapler validate "${DIST_DMG}"

# Generate Checksums
echo "🔐 Generating SHA256 distribution checksums..."
(cd "${BUILD_DIR}" && shasum -a 256 "$(basename "${DIST_DMG}")" "$(basename "${DIST_ARCHIVE}")") > "${SHA_FILE}"
cat "${SHA_FILE}"

if [ -z "${APEX_SKIP_LOCAL_INSTALL:-}" ] && [ -d "/Applications" ]; then
    echo "📲 Updating local /Applications/ApexTerm.app..."
    if [ -d "/Applications/ApexTerm.app" ]; then
        BACKUP_DIR="${BUILD_DIR}/installed-backup-$(date +%Y%m%d%H%M%S)"
        mkdir -p "${BACKUP_DIR}"
        mv "/Applications/ApexTerm.app" "${BACKUP_DIR}/ApexTerm.app"
        # The previous installed app is retained once for rollback, without keeping older generations.
        python3 scripts/prune_build_artifacts.py --installed-backups-only
    fi
    cp -R "${APP_DIR}" "/Applications/ApexTerm.app"
fi

echo "✅ Build & Signed Packaging complete!"
echo "📍 Application: ${APP_DIR} (and /Applications/ApexTerm.app)"
echo "📍 Tarball:     ${DIST_ARCHIVE}"
if [ -f "${DIST_DMG}" ]; then
    echo "📍 Disk Image:  ${DIST_DMG}"
fi
echo "📍 Checksums:   ${SHA_FILE}"
