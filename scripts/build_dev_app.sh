#!/usr/bin/env bash
# Development-only bundle builder for a local fork.
#
# build_app.sh is release-only: it demands a clean master tree, runs the Tart VM quality gate,
# requires the upstream author's Developer ID certificate, and notarizes with Apple. None of that
# is available (or wanted) when you just want to double-click your own build.
#
# This script produces a locally runnable .app with an ad-hoc signature. It is NOT distributable:
# no Developer ID, no notarization, no hardened runtime. Never publish what it builds.
set -euo pipefail

APP_NAME="AetherTerm.app"
BUILD_DIR=".build"
APP_DIR="${BUILD_DIR}/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

VERSION="${1:-1.14.2}"
BUILD_NUMBER="${2:-$(date +%Y%m%d)01}"
CONFIG="${DEV_BUILD_CONFIG:-debug}"

echo "⚡ Building ApexTerm (${CONFIG}) for local use..."
swift build -c "${CONFIG}" --jobs 2

BIN=""
for candidate in \
    ".build/${CONFIG}/ApexTerm" \
    ".build/arm64-apple-macosx/${CONFIG}/ApexTerm"; do
    if [ -x "${candidate}" ]; then BIN="${candidate}"; break; fi
done
if [ -z "${BIN}" ]; then
    echo "❌ Could not locate the built ApexTerm binary under .build/${CONFIG}/."
    exit 1
fi
echo "📋 Using binary: ${BIN}"

echo "📦 Packaging ${APP_NAME} (v${VERSION} Build ${BUILD_NUMBER})..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "Resources/ApexTerm.icns" "${RESOURCES_DIR}/ApexTerm.icns"
cp "${BIN}" "${MACOS_DIR}/ApexTerm"
chmod +x "${MACOS_DIR}/ApexTerm"

# Password-authenticated SSH needs this helper; key/agent/certificate sessions do not.
if [ -x "/opt/homebrew/bin/sshpass" ]; then
    echo "📦 Bundling sshpass helper..."
    cp "/opt/homebrew/bin/sshpass" "${MACOS_DIR}/sshpass"
    chmod +x "${MACOS_DIR}/sshpass"
else
    echo "⚠️  sshpass not found — password-authenticated SSH will fail."
    echo "    Install it with:  brew tap perkons/sshpass && brew install sshpass"
fi

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
    <string>AetherTerm</string>
    <key>CFBundleDisplayName</key>
    <string>AetherTerm</string>
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

# Ad-hoc signature: enough for local launch, nothing more.
codesign --force --deep --sign - "${APP_DIR}"

echo "✅ Local build ready: ${APP_DIR}"
echo "   Launch with:  open ${APP_DIR}"
echo "   (This build is unsigned for distribution — use build_app.sh for release.)"