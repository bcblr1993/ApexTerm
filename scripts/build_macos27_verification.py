#!/usr/bin/env python3
"""Link an isolated QA app against existing SwiftPM modules; never rebuild or publish the product."""
import argparse
import glob
import plistlib
import subprocess
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
    plistlib.dump({'CFBundleIdentifier': 'com.apexterm.qa.' + args.name.lower(), 'CFBundleExecutable': 'Verification', 'CFBundleName': 'ApexTerm ' + args.name + ' QA', 'CFBundlePackageType': 'APPL', 'NSHighResolutionCapable': True}, f)
print(app)
