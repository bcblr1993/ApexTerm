#!/usr/bin/env python3
"""Run UI tests only on the existing, unlocked Tart macos27 guest."""
import os
import json
import re
from pathlib import Path
import shlex
import subprocess
import sys


def run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, **kwargs)


def main():
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        raise ValueError('An explicit diagnostic report directory is required')
    report = Path(sys.argv[1]).resolve()
    root = Path(__file__).resolve().parents[1]
    if report == root or report == Path.cwd().resolve():
        raise ValueError('The report directory must not be the repository or working directory')
    selections = sys.argv[2:]
    if any(not re.fullmatch(r'ApexTermUITests/ApexTermUITests/test[A-Za-z0-9_]+', selection) for selection in selections):
        raise ValueError('Invalid diagnostic test identifier')
    root = Path(__file__).resolve().parents[1]
    user = os.environ.get('APEX_UI_RUNNER_USER', os.environ.get('USER', ''))
    if not user or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in user):
        raise ValueError('Invalid guest SSH user')
    address = os.environ.get('APEX_UI_RUNNER_HOST', '')
    vm = os.environ.get('APEX_UI_TEST_VM', '')
    if vm != 'macos27':
        raise ValueError('UI tests require APEX_UI_TEST_VM=macos27')
    if address and any(c not in '0123456789abcdefABCDEF:.' for c in address):
        raise ValueError('Invalid guest SSH host')
    vm_address = run(['tart', 'ip', vm], capture_output=True, text=True).stdout.strip()
    if address and address != vm_address:
        raise ValueError('The configured runner host does not match the selected Tart VM')
    address = vm_address
    if not address or any(c not in '0123456789abcdefABCDEF:.' for c in address):
        raise ValueError('Start and unlock the selected Tart VM before testing')
    target = f'{user}@{address}'
    ssh = ['ssh', '-A', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', target]
    if not run(ssh + ['/usr/sbin/sysctl -n hw.model'], capture_output=True, text=True).stdout.strip().startswith('VirtualMac'):
        raise ValueError('The selected UI runner is not a macOS virtual machine')
    workspace = run(ssh + ['mktemp -d "$HOME/apex-ui-run.XXXXXX"'],
                    capture_output=True, text=True).stdout.strip()
    if not workspace.startswith('/') or '\n' in workspace:
        raise ValueError('Invalid guest workspace')
    (report / 'guest-workspace.txt').write_text(workspace + '\n')
    archive = report / 'vm-input.tar.gz'
    fixture = report / 'ApexTerm-Reopen.app'
    fixture_for_archive = str(fixture.relative_to(root)) if fixture.is_relative_to(root) else str(fixture)
    run(['tar', '-czf', str(archive), 'UITests',
         'outputs/ui-acceptance/DerivedData/Build/Products',
         fixture_for_archive,
         'outputs/macos27/qa/Verification.app',
         'outputs/ui-acceptance/PhysicalKeyQA.app'], cwd=root)
    run(['scp', '-q', '-o', 'BatchMode=yes', str(archive),
         f'{target}:{workspace}/input.tar.gz'])
    environment_file = report / 'ui-test-environment.json'
    environment_file.write_text(json.dumps({key: os.environ[key] for key in ['APEX_UI_TEST_HOST', 'APEX_UI_TEST_USER'] if os.environ.get(key)}))
    run(['scp', '-q', '-o', 'BatchMode=yes', str(environment_file),
         f'{target}:{workspace}/ui-test-environment.json'])
    script = r'''set -euo pipefail
cd "$1"
LOCK_DIR="$HOME/.apexterm-ui-automation.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another ApexTerm UI run owns this desktop; wait for it to finish." >&2
    exit 1
fi
printf '%s\n' "$PWD" > "$LOCK_DIR/owner"
release_desktop_lock() {
    if [[ "$(cat "$LOCK_DIR/owner" 2>/dev/null)" == "$PWD" ]]; then
        rm -f "$LOCK_DIR/owner"
        rmdir "$LOCK_DIR"
    fi
}
trap release_desktop_lock EXIT
cleanup_qa_host() {
python3 - <<'PY_CLEANUP'
import json, os, pathlib, signal, subprocess
root = pathlib.Path.cwd().resolve()
metadata = root / 'reports/qa-host.json'
if not metadata.exists():
    raise SystemExit(0)
host = json.loads(metadata.read_text())
app = pathlib.Path(host['path']).resolve()
if not app.is_relative_to(root) or not host['bundleIdentifier'].startswith('com.apexterm.qa.'):
    raise SystemExit('Refusing to stop an application outside this QA workspace')
executable = str(app / 'Contents/MacOS/Verification')
rows = [line.strip().split(None, 2) for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,comm='], text=True).splitlines()]
rows = [(int(p[0]), int(p[1]), p[2]) for p in rows if len(p) == 3]
parents = {pid for pid, _, command in rows if command == executable}
owned = set(parents)
while True:
    descendants = {pid for pid, parent, _ in rows if parent in owned}
    if descendants <= owned:
        break
    owned.update(descendants)
stopped_children = []
for pid, _, command in rows:
    if pid in owned - parents and pathlib.Path(command).name in ('ssh', 'scp', 'sshpass'):
        try:
            os.kill(pid, signal.SIGKILL)
            stopped_children.append(pid)
        except ProcessLookupError:
            pass
for pid in parents:
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
(root / 'reports/qa-cleanup.json').write_text(json.dumps({'ownedHostPIDs': sorted(parents), 'ownedChildPIDs': stopped_children}, indent=2))
PY_CLEANUP
}
trap 'cleanup_qa_host; release_desktop_lock' EXIT
tar -xzf input.tar.gz
mkdir -p reports
python3 - <<'PY_KEY_FIXTURE'
import hashlib, json, pathlib, plistlib, shutil, subprocess
source_path = pathlib.Path('outputs/ui-acceptance/PhysicalKeyQA.app')
assert not source_path.is_symlink()
source = source_path.resolve()
identifier = 'com.apexterm.qa.physicalkeys'
assert source.is_relative_to(pathlib.Path.cwd().resolve())
assert plistlib.loads((source / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] == identifier
requirement = '=identifier "com.apexterm.qa.physicalkeys" and anchor apple generic and certificate leaf[subject.OU] = "5984KQD4D7"'
subprocess.run(['codesign', '--verify', '--deep', '--strict', '-R', requirement, str(source)], check=True)
tools = pathlib.Path.home() / '.apexterm-ui-tools'
assert not tools.is_symlink()
tools.mkdir(exist_ok=True)
destination = tools / 'PhysicalKeyQA.app'
assert not destination.is_symlink()
if destination.exists():
    assert plistlib.loads((destination / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] == identifier
    subprocess.run(['codesign', '--verify', '--deep', '--strict', '-R', requirement, str(destination)], check=True)
    shutil.rmtree(destination)
shutil.copytree(source, destination)
helper = destination / 'Contents/MacOS/PhysicalKeyPoster'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
pathlib.Path('reports/physical-key-fixture.json').write_text(json.dumps({'bundleIdentifier': identifier, 'executableSHA256': hashlib.sha256(helper.read_bytes()).hexdigest()}))
# Launch Services makes the signed helper, rather than sshd, responsible for TCC.
# open can exit zero even when its application exits 77: require fresh helper proof.
import tempfile
with tempfile.TemporaryDirectory(prefix='apex-key-preflight-') as directory:
    output = pathlib.Path(directory) / 'stdout'
    error = pathlib.Path(directory) / 'stderr'
    subprocess.run(['/usr/bin/open', '-n', '-g', '-W', '--stdout', str(output), '--stderr', str(error),
                    '-a', str(destination), '--args', '--preflight'], check=True, timeout=15)
    if not output.exists() or output.read_text() != 'APEX_PHYSICAL_KEY_OK --preflight\n':
        raise RuntimeError('Physical key preflight did not succeed: ' + (error.read_text() if error.exists() else 'missing helper result'))
PY_KEY_FIXTURE
xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0 UITests/Fixtures/IMEInputSourceRestorer.swift -o reports/IMEInputSourceRestorer
xcodebuild build-for-testing -project UITests/ApexTermUITests.xcodeproj -scheme ApexTermUITests -destination 'platform=macOS,arch=arm64' -derivedDataPath outputs/ui-acceptance/RemoteDerivedData -jobs 2 ONLY_ACTIVE_ARCH=YES 2>&1 | tee reports/remote-build.log
python3 - <<'PY'
import hashlib, json, os, pathlib, plistlib, uuid
app = pathlib.Path('outputs/macos27/qa/Verification.app').resolve()
metadata = app / 'Contents/Info.plist'
info = plistlib.loads(metadata.read_bytes())
assert info['CFBundleIdentifier'].startswith('com.apexterm.qa.')
info['CFBundleIdentifier'] += '.' + uuid.uuid4().hex
metadata.write_bytes(plistlib.dumps(info))
pathlib.Path('reports/qa-host.json').write_text(json.dumps({'path': str(app), 'bundleIdentifier': info['CFBundleIdentifier'], 'executableSHA256': hashlib.sha256((app / 'Contents/MacOS/Verification').read_bytes()).hexdigest()}, indent=2))
def targets(config):
    result = [t for g in config.get('TestConfigurations', []) for t in g.get('TestTargets', [])]
    return result or [v for k, v in config.items() if k != '__xctestrun_metadata__' and isinstance(v, dict)]
source, = pathlib.Path('outputs/ui-acceptance/DerivedData/Build/Products').glob('*.xctestrun')
destination, = pathlib.Path('outputs/ui-acceptance/RemoteDerivedData/Build/Products').glob('*.xctestrun')
environment = targets(plistlib.loads(source.read_bytes()))[0].get('EnvironmentVariables', {})
environment.update(json.loads(pathlib.Path('ui-test-environment.json').read_text()))
if not all(environment.get(key) for key in ['APEX_UI_TEST_HOST', 'APEX_UI_TEST_USER']):
    raise ValueError('Missing real SSH target configuration for UI acceptance')
config = plistlib.loads(destination.read_bytes())
for target in targets(config):
    target.setdefault('EnvironmentVariables', {}).update({key: environment[key] for key in ['APEX_UI_TEST_HOST', 'APEX_UI_TEST_USER']})
    target['EnvironmentVariables']['APEX_UI_APP_PATH'] = str(app)
    target['EnvironmentVariables']['APEX_UI_PRODUCT_APP_PATH'] = str(next(pathlib.Path('outputs/ui-acceptance').glob('*/ApexTerm-Reopen.app')).resolve())
    target['EnvironmentVariables']['APEX_UI_INPUT_SOURCE_RESTORER'] = str(pathlib.Path('reports/IMEInputSourceRestorer').resolve())
    target['EnvironmentVariables']['APEX_UI_PHYSICAL_KEY_HELPER'] = str(pathlib.Path.home() / '.apexterm-ui-tools/PhysicalKeyQA.app/Contents/MacOS/PhysicalKeyPoster')
    target['EnvironmentVariables']['APEX_UI_PHYSICAL_KEY_TARGET'] = info['CFBundleIdentifier']
    if os.environ.get('SSH_AUTH_SOCK'):
        target['EnvironmentVariables']['SSH_AUTH_SOCK'] = os.environ['SSH_AUTH_SOCK']
        target['EnvironmentVariables']['APEX_UI_AGENT_SOCKET'] = os.environ['SSH_AUTH_SOCK']
destination.write_bytes(plistlib.dumps(config))
# Xcode's macOS UI runner is sandboxed even for an unsandboxed app.
# Its SSH verification child needs the forwarded Unix-domain agent socket.
# Adjust only this disposable test runner; never the product or QA host.
import subprocess, tempfile
runner = pathlib.Path('outputs/ui-acceptance/RemoteDerivedData/Build/Products/Debug/ApexTermUITests-Runner.app').resolve()
assert runner.is_relative_to(pathlib.Path.cwd()) and runner.name == 'ApexTermUITests-Runner.app'
entitlements = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(runner)], stderr=subprocess.DEVNULL))
entitlements['com.apple.security.app-sandbox'] = False
with tempfile.NamedTemporaryFile(suffix='.plist') as file:
    file.write(plistlib.dumps(entitlements))
    file.flush()
    subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', file.name, str(runner)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(runner)], check=True)
verified = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(runner)], stderr=subprocess.DEVNULL))
assert verified.get('com.apple.security.app-sandbox') is False
pathlib.Path('reports/ui-runner-entitlements.json').write_text(json.dumps({'runner': str(runner), 'sandboxed': False, 'productModified': False}, indent=2))
PY
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f outputs/macos27/qa/Verification.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(find outputs/ui-acceptance -maxdepth 2 -name ApexTerm-Reopen.app -type d | head -1)"
files=(outputs/ui-acceptance/RemoteDerivedData/Build/Products/*.xctestrun)
[[ ${#files[@]} == 1 ]]
xcodebuild test-without-building -xctestrun "${files[0]}" -destination 'platform=macOS,arch=arm64' -jobs 2 -parallel-testing-enabled NO -resultBundlePath reports/UI.xcresult "${@:2}" 2>&1 | tee reports/ui-tests.log
'''
    result = subprocess.run(ssh + [shlex.join(['bash', '-s', '--', workspace] + ['-only-testing:' + selection for selection in selections])],
                            input=script, text=True)
    # Preserve failures as well as successes; the caller validates exact case results.
    run(ssh + [shlex.join(['tar', '-czf', workspace + '/results.tar.gz', '-C', workspace + '/reports', '.'])])
    results = report / 'remote-results.tar.gz'
    run(['scp', '-q', '-o', 'BatchMode=yes',
         f'{target}:{workspace}/results.tar.gz', str(results)])
    run(['tar', '-xzf', str(results), '-C', str(report)])
    if result.returncode:
        raise subprocess.CalledProcessError(result.returncode, 'guest UI execution')


if __name__ == '__main__':
    main()
