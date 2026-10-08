#!/usr/bin/env python3
"""Link an isolated QA app against existing SwiftPM modules; never rebuild or publish the product."""
import argparse
import glob
import plistlib
import subprocess
import shutil
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Debug')
parser.add_argument('--name', default='Verification')
parser.add_argument('--baseline', action='store_true', help='Use the archived v1.3.0 modules')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
if not args.name.replace('-', '').isalnum():
    parser.error('Use an alphanumeric app name')
app = root / 'outputs/macos27/qa' / (args.name + '.app')
# Old generated QA bundles are disposable; running apps and their unsaved UI state stay intact.
running = [line.strip() for line in subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()]
qa_prefixes = (str(app.parent) + '/', str(app.parent.relative_to(root)) + '/')
active_qa = [executable for executable in running
             if executable.startswith(qa_prefixes)
             and executable.endswith('/Contents/MacOS/Verification')]
if active_qa:
    parser.error('A QA app is already running; quit it before building another verification bundle')
for previous in app.parent.glob('*.app'):
    prefix = str(previous) + '/'
    active = any(executable.startswith(prefix) for executable in running)
    if previous == app and active:
        parser.error('This QA app is running; close it before rebuilding the same bundle')
    if previous == app or active or previous.is_symlink():
        continue
    metadata = previous / 'Contents/Info.plist'
    try:
        with metadata.open('rb') as file:
            info = plistlib.load(file)
        if str(info.get('CFBundleIdentifier', '')).startswith('com.apexterm.qa.') and info.get('CFBundleExecutable') == 'Verification':
            shutil.rmtree(previous)
    except (OSError, plistlib.InvalidFileException):
        continue
(app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
modules_root = root / 'outputs/macos27/baseline/source' if args.baseline else root
objects = []
for module in ['ApexCore', 'ApexSSH', 'ApexTerminal', 'ApexUI']:
    objects += glob.glob(str(modules_root / f'.build/out/Intermediates.noindex/ApexTerm.build/{args.configuration}/{module}-t.build/Objects-normal/arm64/*.o'))
if not objects:
    parser.error('Build the chosen SwiftPM configuration first')
command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-I', str(modules_root / f'.build/out/Products/{args.configuration}'), *[str(file) for file in sorted((root / 'scripts/verification').glob('*.swift'))], *objects, '-o', str(app / 'Contents/MacOS/Verification')]
if args.baseline:
    command[2:2] = ['-D', 'APEX_BASELINE']
result = subprocess.run(command, capture_output=True, text=True)
(root / f'outputs/macos27/qa/compile-{args.name}.log').write_text(result.stdout + result.stderr)
if result.returncode:
    print(result.stderr)
    raise SystemExit(result.returncode)
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier': 'com.apexterm.qa.' + args.name.lower(), 'CFBundleExecutable': 'Verification', 'CFBundleName': 'AetherTerm ' + args.name + ' QA', 'CFBundlePackageType': 'APPL', 'NSHighResolutionCapable': True, 'NSLocalNetworkUsageDescription': '连接你选择的验收服务器，验证 SSH、SFTP 文件传输和系统监控。'}, f)
print(app)
