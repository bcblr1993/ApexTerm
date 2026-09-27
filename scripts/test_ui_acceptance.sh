#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if [[ -f "${APEX_UI_CONFIG_FILE:-$ROOT_DIR/.ui-acceptance.env}" ]]; then
    source "${APEX_UI_CONFIG_FILE:-$ROOT_DIR/.ui-acceptance.env}"
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--preflight-only" ) ]]; then
    echo 'Usage: test_ui_acceptance.sh [--preflight-only]' >&2
    exit 2
fi
REPORT_DIR="${APEX_UI_REPORT_ROOT:-$ROOT_DIR/outputs/ui-acceptance}/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$REPORT_DIR"
STAGE=prerequisites
finish_report() {
    local result=$?
    printf 'stage=%s\nexit_code=%s\n' "$STAGE" "$result" > "$REPORT_DIR/run-status.txt"
    if (( result != 0 )); then
        echo "UI acceptance failed at $STAGE; report: $REPORT_DIR" >&2
    fi
}
trap finish_report EXIT
git rev-parse HEAD > "$REPORT_DIR/source-commit.txt"
cp UITests/ApexTermUITests.swift "$REPORT_DIR/ApexTermUITests.swift"
shasum -a 256 UITests/ApexTermUITests.swift > "$REPORT_DIR/test-source-sha256.txt"
# Requires an unlocked macOS desktop and Xcode UI-testing permissions.
# Failure, missing tools or denied permissions stop the release; no silent fallback.
command -v xcodebuild >/dev/null
# Bash 3.2 can report zero after a parameter-expansion error with an EXIT trap.
# Explicit exits preserve fail-closed behavior on the system shell as well as Bash 5.
if [[ -z "${APEX_UI_TEST_HOST:-}" ]]; then
    echo 'Set APEX_UI_TEST_HOST to the dedicated SSH test machine' >&2
    exit 1
fi
if [[ -z "${APEX_UI_TEST_USER:-}" ]]; then
    echo 'Set APEX_UI_TEST_USER to the dedicated SSH test user' >&2
    exit 1
fi
automationmodetool help > "$REPORT_DIR/automation-mode.txt" 2>&1
if ! grep -qi 'Automation Mode is enabled' "$REPORT_DIR/automation-mode.txt"; then
    echo "Automation Mode is currently disabled; Xcode must obtain authenticated activation when UI tests start."
fi
if [[ "${1:-}" == "--preflight-only" ]]; then
    STAGE=prerequisites-passed
    echo "UI tools and host configuration checked; authenticated full UI execution is still required before packaging."
    exit 0
fi
STAGE=product-build
swift build -c release --jobs 2 2>&1 | tee "$REPORT_DIR/product-build.log"
STAGE=qa-host-build
python3 scripts/build_macos27_verification.py --configuration Release 2>&1 | tee "$REPORT_DIR/qa-host-build.log"
"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" \
    -f "$ROOT_DIR/outputs/macos27/qa/Verification.app"
STAGE=ui-test-build
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
        'APEX_UI_APP_PATH': str(pathlib.Path('outputs/macos27/qa/Verification.app').resolve()),
    })
# Keep alongside build products so __TESTROOT__ paths still resolve correctly.
source.write_bytes(plistlib.dumps(config))
(reports / 'xctestrun-path.txt').write_text(str(source.resolve()))
PY
TEST_RUN_FILE="$(cat "$REPORT_DIR/xctestrun-path.txt")"
STAGE=ui-test-execution
if [[ -n "${APEX_UI_TEST_VM:-}${APEX_UI_RUNNER_HOST:-}" ]]; then
    python3 scripts/run_ui_tests_remotely.py "$REPORT_DIR" 2>&1 | tee "$REPORT_DIR/remote-execution.log"
else
xcodebuild test-without-building -xctestrun "$TEST_RUN_FILE" \
    -destination 'platform=macOS,arch=arm64' -jobs 2 -parallel-testing-enabled NO \
    -resultBundlePath "$REPORT_DIR/UI.xcresult" \
    2>&1 | tee "$REPORT_DIR/ui-tests.log"
fi
STAGE=ui-result-verification
xcrun xcresulttool get test-results summary --path "$REPORT_DIR/UI.xcresult" --compact \
    > "$REPORT_DIR/summary.json"
xcrun xcresulttool get test-results tests --path "$REPORT_DIR/UI.xcresult" --compact \
    > "$REPORT_DIR/test-cases.json"
if ! cmp -s UITests/ApexTermUITests.swift "$REPORT_DIR/ApexTermUITests.swift"; then
    echo 'UI test source changed during acceptance; rerun before packaging.' >&2
    exit 1
fi
python3 scripts/verify_ui_results.py "$REPORT_DIR/summary.json" --details "$REPORT_DIR/test-cases.json" --source "$REPORT_DIR/ApexTermUITests.swift"
STAGE=passed
echo "UI acceptance passed: $REPORT_DIR/UI.xcresult"
