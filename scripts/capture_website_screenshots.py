#!/usr/bin/env python3
"""Capture actual branded native views in macOS 27 on Tart or an authorized remote Mac."""
import argparse
import json
import pathlib
import plistlib
import re
import shlex
import shutil
import subprocess
import tempfile
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / 'outputs/macos27/qa/AetherTermWebsite.app'
THEMES = ['classic', 'modern', 'tokyo', 'mocha', 'nord', 'dracula', 'latte',
          'onedark', 'gruvbox', 'everforest', 'rosepine', 'solarized']
PAGES = ['main', 'editor', 'settings', 'about']


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--user', required=True)
    parser.add_argument('--host', help='Explicitly authorized remote Mac SSH address; otherwise use Tart macos27.')
    args = parser.parse_args()
    if not args.user.replace('-', '').replace('_', '').isalnum():
        parser.error('Use the guest account name.')
    if not APP.exists():
        parser.error('Build the current debug modules and AetherTermWebsite QA app first.')
    address = args.host or run(['tart', 'ip', 'macos27'], capture_output=True, text=True).stdout.strip()
    if address.startswith('-') or any(c.isspace() for c in address):
        parser.error('Invalid SSH address.')
    if not address:
        parser.error('Start and unlock the macos27 VM first.')
    metadata = APP / 'Contents/Info.plist'
    info = plistlib.loads(metadata.read_bytes())
    if info.get('CFBundleIdentifier') != 'com.apexterm.qa.aethertermwebsite':
        parser.error('Only the isolated website QA bundle may be captured.')
    version = re.search(r'## \[v(\d+\.\d+\.\d+)\]', (ROOT / 'CHANGELOG.md').read_text()).group(1)
    info['CFBundleShortVersionString'] = version
    info['CFBundleVersion'] = 'development-preview'
    info['CFBundleIconFile'] = 'ApexTerm'
    resources = APP / 'Contents/Resources'
    resources.mkdir(exist_ok=True)
    shutil.copy2(ROOT / 'Resources/ApexTerm.icns', resources / 'ApexTerm.icns')
    metadata.write_bytes(plistlib.dumps(info))
    target = args.user + '@' + address
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=3', target]
    model = run(ssh + ['/usr/sbin/sysctl -n hw.model'], capture_output=True, text=True).stdout.strip()
    version = run(ssh + ['/usr/bin/sw_vers -productVersion'], capture_output=True, text=True).stdout.strip()
    if (not args.host and not model.startswith('VirtualMac')) or not version.startswith('27.'):
        parser.error('Screenshots require macOS 27; default Tart mode also requires VirtualMac.')
    workspace = run(ssh + ['mktemp -d "$HOME/aetherterm-site.XXXXXX"'], capture_output=True, text=True).stdout.strip()
    if not workspace.startswith('/') or '\n' in workspace:
        raise ValueError('Invalid guest workspace.')
    output = ROOT / 'outputs/macos27/website'
    output.mkdir(parents=True, exist_ok=True)
    archive = output / 'qa-input.tar.gz'
    run(['tar', '-czf', str(archive), '-C', str(ROOT), str(APP.relative_to(ROOT))])
    run(['scp', '-q', str(archive), target + ':' + workspace + '/qa-input.tar.gz'])
    command = 'cd ' + shlex.quote(workspace) + ' && tar -xzf qa-input.tar.gz && mkdir -p captures && '
    command += 'APEX_QA_UI_RUN_ID=' + shlex.quote(str(uuid.uuid4())) + ' APEX_QA_MONITOR=0 '
    command += 'APEX_QA_WEBSITE_CAPTURE=' + shlex.quote(workspace + '/captures') + ' '
    command += shlex.quote(workspace + '/outputs/macos27/qa/AetherTermWebsite.app/Contents/MacOS/Verification')
    if args.host:
        app_path = workspace + '/outputs/macos27/qa/AetherTermWebsite.app'
        run_id = str(uuid.uuid4())
        command = 'cd ' + shlex.quote(workspace) + ' && tar -xzf qa-input.tar.gz && mkdir -p captures && '
        command += 'open -W -n -a ' + shlex.quote(app_path)
        for value in ['APEX_QA_UI_RUN_ID=' + run_id, 'APEX_QA_MONITOR=0', 'APEX_QA_WEBSITE_CAPTURE=' + workspace + '/captures']:
            command += ' --env ' + shlex.quote(value)
    run(ssh + [command])
    expected = [theme + '-' + page + '.png' for theme in THEMES for page in PAGES]
    # Validate this run independently so older completed captures cannot mask a failure.
    with tempfile.TemporaryDirectory(prefix='capture-download-', dir=output) as temporary:
        run(['scp', '-q', '-r', target + ':' + workspace + '/captures', temporary])
        fresh = pathlib.Path(temporary) / 'captures'
        if not (fresh / 'capture-complete.txt').is_file() or any(not (fresh / name).is_file() for name in expected):
            raise RuntimeError('Native capture incomplete; inspect capture-error.txt in ' + workspace + '/captures.')
        capture = output / 'captures'
        capture.mkdir(exist_ok=True)
        for name in expected + ['capture-complete.txt']:
            shutil.copy2(fresh / name, capture / name)
        (capture / 'capture-error.txt').unlink(missing_ok=True)
    head = run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    (output / 'manifest.json').write_text(json.dumps({'sourceCommit': head, 'vm': None if args.host else 'macos27',
        'captureMethod': 'remote-native' if args.host else 'tart-native',
        'systemVersion': version, 'model': model, 'guestWorkspace': workspace,
        'demoData': True, 'screenshots': expected}, indent=2) + '\n')
    print(output)


if __name__ == '__main__':
    main()
