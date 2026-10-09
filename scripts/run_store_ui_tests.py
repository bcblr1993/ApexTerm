#!/usr/bin/env python3
"""Verify an isolated Store QA app in the existing macos27 desktop; retain results."""
import argparse
import getpass
import hashlib
import json
import pathlib
import plistlib
import re
import shlex
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=pathlib.Path)
    parser.add_argument('report', type=pathlib.Path)
    parser.add_argument('--user', default=getpass.getuser())
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if not info.get('CFBundleIdentifier', '').startswith('com.apexterm.qa.store.') or info.get('ApexBuildPurpose') != 'sandboxQA':
        parser.error('Only an isolated sandbox QA product is allowed; never re-sign a distribution app.')
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.user):
        parser.error('Invalid VM user')
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
    report = args.report.resolve()
    report.mkdir(parents=True, exist_ok=False)
    host = run(['tart', 'ip', 'macos27'], capture_output=True, text=True).stdout.strip()
    if not re.fullmatch(r'[0-9a-fA-F:.]+', host):
        raise RuntimeError('macos27 must be running')
    target = args.user + '@' + host
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', target]
    model = run(ssh + ['sysctl -n hw.model'], capture_output=True, text=True).stdout.strip()
    if not model.startswith('VirtualMac'):
        raise RuntimeError('The runner must be the existing Tart VM')
    workspace = run(ssh + ['mktemp -d "$HOME/aetherterm-store-ui.XXXXXX"'], capture_output=True, text=True).stdout.strip()
    (report / 'guest-workspace.txt').write_text(workspace + '\n')
    hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (app / 'Contents/MacOS').iterdir()}
    (report / 'product-hashes.json').write_text(json.dumps(hashes, indent=2))
    archive = report / 'input.tar.gz'
    run(['tar', '-czf', str(archive), '-C', str(ROOT), 'UITests', '-C', str(app.parent), app.name])
    run(['scp', '-q', str(archive), target + ':' + workspace + '/input.tar.gz'])
    script = r'''set -euo pipefail
cd "$1"
LOCK_DIR="$HOME/.apexterm-ui-automation.lock"
mkdir "$LOCK_DIR" || { echo 'Another UI run owns this VM desktop'; exit 1; }
printf '%s\n' "$PWD" > "$LOCK_DIR/owner"
cleanup() {
    if [[ "$(cat "$LOCK_DIR/owner" 2>/dev/null)" == "$PWD" ]]; then
        rm -f "$LOCK_DIR/owner"
        rmdir "$LOCK_DIR"
    fi
}
trap cleanup EXIT
mkdir reports
tar -xzf input.tar.gz
codesign --verify --deep --strict "$2"
python3 - "$2" <<'PY_VERIFY'
import hashlib,json,pathlib,plistlib,subprocess,sys
app=pathlib.Path(sys.argv[1]).resolve()
ent=plistlib.loads(subprocess.check_output(['codesign','-d','--entitlements',':-',str(app)],stderr=subprocess.DEVNULL))
assert ent.get('com.apple.security.app-sandbox') is True
pathlib.Path('reports/product-before.json').write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (app/'Contents/MacOS').iterdir()},indent=2))
PY_VERIFY
xcodebuild build-for-testing -project UITests/StoreSandboxUITests.xcodeproj -scheme StoreSandboxUITests -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData -jobs 2 > reports/build.log 2>&1
python3 - "$2" <<'PY_CONFIG'
import pathlib,plistlib,subprocess,sys,tempfile
source,=pathlib.Path('DerivedData/Build/Products').glob('*.xctestrun')
config=plistlib.loads(source.read_bytes())
targets=[t for g in config.get('TestConfigurations',[]) for t in g.get('TestTargets',[])]
if not targets: targets=[v for k,v in config.items() if k!='__xctestrun_metadata__' and isinstance(v,dict)]
assert targets
for t in targets: t.setdefault('EnvironmentVariables',{})['APEX_STORE_UI_APP_PATH']=str(pathlib.Path(sys.argv[1]).resolve())
source.write_bytes(plistlib.dumps(config))
runner=pathlib.Path('DerivedData/Build/Products/Debug/StoreSandboxUITests-Runner.app').resolve()
assert runner.is_relative_to(pathlib.Path.cwd())
ent=plistlib.loads(subprocess.check_output(['codesign','-d','--entitlements',':-',str(runner)],stderr=subprocess.DEVNULL))
ent['com.apple.security.app-sandbox']=False
with tempfile.NamedTemporaryFile(suffix='.plist') as f:
 f.write(plistlib.dumps(ent));f.flush()
 subprocess.run(['codesign','--force','--sign','-','--entitlements',f.name,str(runner)],check=True)
PY_CONFIG
"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" -f "$2"
files=(DerivedData/Build/Products/*.xctestrun)
test_exit=0
xcodebuild test-without-building -xctestrun "${files[0]}" -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -resultBundlePath reports/UI.xcresult > reports/ui-tests.log 2>&1 || test_exit=$?
codesign --verify --deep --strict "$2"
python3 - "$2" <<'PY_AFTER'
import hashlib,json,pathlib,sys
app=pathlib.Path(sys.argv[1])
pathlib.Path('reports/product-after.json').write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (app/'Contents/MacOS').iterdir()},indent=2))
PY_AFTER
exit "$test_exit"
'''
    result = subprocess.run(ssh + [shlex.join(['bash', '-s', '--', workspace, app.name])], input=script, text=True)
    run(ssh + [shlex.join(['tar', '-czf', workspace + '/results.tar.gz', '-C', workspace + '/reports', '.'])])
    run(['scp', '-q', target + ':' + workspace + '/results.tar.gz', str(report / 'results.tar.gz')])
    run(['tar', '-xzf', str(report / 'results.tar.gz'), '-C', str(report)])
    for name in ('product-before.json', 'product-after.json'):
        if json.loads((report / name).read_text()) != hashes:
            raise RuntimeError('QA product bytes changed during testing')
    summary = run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(report / 'UI.xcresult'), '--compact'], capture_output=True, text=True).stdout
    (report / 'summary.json').write_text(summary)
    data = json.loads(summary)
    if result.returncode or data.get('failedTests') or data.get('skippedTests') or data.get('passedTests', 0) < 5:
        raise RuntimeError('All Store sandbox UI tests must pass with zero skips; see retained reports')
    print(summary)


if __name__ == '__main__':
    main()
