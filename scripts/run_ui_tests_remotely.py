#!/usr/bin/env python3
"""Run UI tests on a dedicated Mac or one existing, unlocked Tart guest."""
import os
from pathlib import Path
import shlex
import subprocess
import sys


def run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, **kwargs)


def main():
    report = Path(sys.argv[1]).resolve()
    root = Path(__file__).resolve().parents[1]
    user = os.environ.get('APEX_UI_RUNNER_USER', os.environ.get('USER', ''))
    if not user or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in user):
        raise ValueError('Invalid guest SSH user')
    address = os.environ.get('APEX_UI_RUNNER_HOST', '')
    if not address:
        address = run(['tart', 'ip', os.environ['APEX_UI_TEST_VM']], capture_output=True, text=True).stdout.strip()
    if not address or any(c not in '0123456789abcdefABCDEF:.' for c in address):
        raise ValueError('Start and unlock the selected Tart VM before testing')
    target = f'{user}@{address}'
    ssh = ['ssh', '-A', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', target]
    workspace = run(ssh + ['mktemp -d "$HOME/apex-ui-run.XXXXXX"'],
                    capture_output=True, text=True).stdout.strip()
    if not workspace.startswith('/') or '\n' in workspace:
        raise ValueError('Invalid guest workspace')
    (report / 'guest-workspace.txt').write_text(workspace + '\n')
    archive = report / 'vm-input.tar.gz'
    run(['tar', '-czf', str(archive), 'UITests',
         'outputs/ui-acceptance/DerivedData/Build/Products',
         'outputs/macos27/qa/Verification.app'], cwd=root)
    run(['scp', '-q', '-o', 'BatchMode=yes', str(archive),
         f'{target}:{workspace}/input.tar.gz'])
    script = r'''set -euo pipefail
cd "$1"
tar -xzf input.tar.gz
mkdir -p reports
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f outputs/macos27/qa/Verification.app
xcodebuild build-for-testing -project UITests/ApexTermUITests.xcodeproj -scheme ApexTermUITests -destination 'platform=macOS,arch=arm64' -derivedDataPath outputs/ui-acceptance/RemoteDerivedData -jobs 2 2>&1 | tee reports/remote-build.log
python3 - <<'PY'
import os, pathlib, plistlib
def targets(config):
    result = [t for g in config.get('TestConfigurations', []) for t in g.get('TestTargets', [])]
    return result or [v for k, v in config.items() if k != '__xctestrun_metadata__' and isinstance(v, dict)]
source, = pathlib.Path('outputs/ui-acceptance/DerivedData/Build/Products').glob('*.xctestrun')
destination, = pathlib.Path('outputs/ui-acceptance/RemoteDerivedData/Build/Products').glob('*.xctestrun')
environment = targets(plistlib.loads(source.read_bytes()))[0].get('EnvironmentVariables', {})
config = plistlib.loads(destination.read_bytes())
for target in targets(config):
    target.setdefault('EnvironmentVariables', {}).update({key: environment[key] for key in ['APEX_UI_TEST_HOST', 'APEX_UI_TEST_USER']})
    if os.environ.get('SSH_AUTH_SOCK'):
        target['EnvironmentVariables']['SSH_AUTH_SOCK'] = os.environ['SSH_AUTH_SOCK']
destination.write_bytes(plistlib.dumps(config))
PY
files=(outputs/ui-acceptance/RemoteDerivedData/Build/Products/*.xctestrun)
[[ ${#files[@]} == 1 ]]
xcodebuild test-without-building -xctestrun "${files[0]}" -destination 'platform=macOS,arch=arm64' -jobs 2 -parallel-testing-enabled NO -resultBundlePath reports/UI.xcresult 2>&1 | tee reports/ui-tests.log
'''
    result = subprocess.run(ssh + [shlex.join(['bash', '-s', '--', workspace])],
                            input=script, text=True)
    # Preserve failures as well as successes; the caller validates exact case results.
    run(['scp', '-q', '-r', '-o', 'BatchMode=yes',
         f'{target}:{workspace}/reports/.', str(report)])
    if result.returncode:
        raise subprocess.CalledProcessError(result.returncode, 'guest UI execution')


if __name__ == '__main__':
    main()
