#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# Requires an unlocked macOS desktop and Xcode UI-testing permissions.
# Failure, missing tools or denied permissions stop the release; no silent fallback.
command -v xcodebuild >/dev/null
: "${APEX_UI_TEST_HOST:?Set APEX_UI_TEST_HOST to the dedicated SSH test machine}"
: "${APEX_UI_TEST_USER:?Set APEX_UI_TEST_USER to the dedicated SSH test user}"
if ! automationmodetool help 2>&1 | grep -q 'Automation Mode is enabled'; then
    echo "UI acceptance requires Automation Mode. Enable it with user authentication before testing."
    exit 1
fi
swift build -c release --jobs 2
python3 scripts/build_macos27_verification.py --configuration Release
"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" \
    -f "$ROOT_DIR/outputs/macos27/qa/Verification.app"
REPORT_DIR="$ROOT_DIR/outputs/ui-acceptance/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$REPORT_DIR"
git rev-parse HEAD > "$REPORT_DIR/source-commit.txt"
xcodebuild build-for-testing -project UITests/ApexTermUITests.xcodeproj -scheme ApexTermUITests \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath outputs/ui-acceptance/DerivedData \
    -jobs 2 2>&1 | tee "$REPORT_DIR/build.log"
python3 - "$REPORT_DIR" <<'PY'
import os, pathlib, plistlib, sys
reports = pathlib.Path(sys.argv[1])
sources = list(pathlib.Path('outputs/ui-acceptance/DerivedData/Build/Products').glob('*.xctestrun'))
if len(sources) != 1:
    raise SystemExit('Expected exactly one current UI xctestrun configuration')
source = sources[0]
config = plistlib.loads(source.read_bytes())
targets = [target for group in config.get('TestConfigurations', []) for target in group.get('TestTargets', [])]
if not targets:
    targets = [v for k, v in config.items() if k != '__xctestrun_metadata__' and isinstance(v, dict)]
if not targets:
    raise SystemExit('Missing UI test target configuration')
for target in targets:
    target.setdefault('EnvironmentVariables', {}).update({
        'APEX_UI_TEST_HOST': os.environ['APEX_UI_TEST_HOST'],
        'APEX_UI_TEST_USER': os.environ['APEX_UI_TEST_USER'],
    })
# Keep alongside build products so __TESTROOT__ paths still resolve correctly.
source.write_bytes(plistlib.dumps(config))
(reports / 'xctestrun-path.txt').write_text(str(source.resolve()))
PY
TEST_RUN_FILE="$(cat "$REPORT_DIR/xctestrun-path.txt")"
xcodebuild test-without-building -xctestrun "$TEST_RUN_FILE" \
    -destination 'platform=macOS,arch=arm64' -jobs 2 -parallel-testing-enabled NO \
    -resultBundlePath "$REPORT_DIR/UI.xcresult" \
    2>&1 | tee "$REPORT_DIR/ui-tests.log"
xcrun xcresulttool get test-results summary --path "$REPORT_DIR/UI.xcresult" --compact \
    > "$REPORT_DIR/summary.json"
xcrun xcresulttool get test-results tests --path "$REPORT_DIR/UI.xcresult" --compact \
    > "$REPORT_DIR/test-cases.json"
python3 scripts/verify_ui_results.py "$REPORT_DIR/summary.json" --details "$REPORT_DIR/test-cases.json"
echo "UI acceptance passed: $REPORT_DIR/UI.xcresult"
