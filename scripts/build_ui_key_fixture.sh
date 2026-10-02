#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/outputs/ui-acceptance/PhysicalKeyQA.app"
python3 - "$APP" <<'PY_GUARD'
import pathlib,plistlib,sys
p=pathlib.Path(sys.argv[1])
for item in [p,p/'Contents',p/'Contents/MacOS',p/'Contents/MacOS/PhysicalKeyPoster',p/'Contents/Info.plist']:
    assert not item.is_symlink(), 'Refuse a symlink in the generated QA fixture'
if p.exists():
    assert plistlib.loads((p/'Contents/Info.plist').read_bytes())['CFBundleIdentifier']=='com.apexterm.qa.physicalkeys', 'Refuse another application'
PY_GUARD
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -swift-version 6 -parse-as-library -O "$ROOT/UITests/Fixtures/PhysicalKeyPoster.swift" -o "$APP/Contents/MacOS/PhysicalKeyPoster"
/usr/bin/strip -S "$APP/Contents/MacOS/PhysicalKeyPoster"
python3 - "$APP" <<'PY'
import pathlib,plistlib,sys
p=pathlib.Path(sys.argv[1])/'Contents/Info.plist'
p.write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.apexterm.qa.physicalkeys','CFBundleExecutable':'PhysicalKeyPoster','CFBundleName':'ApexTerm Physical Key QA','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0','CFBundleVersion':'1','LSUIElement':True,'LSMinimumSystemVersion':'14.0'}))
PY
codesign --force --deep --sign 'Developer ID Application: YanNan Chen (5984KQD4D7)' --identifier com.apexterm.qa.physicalkeys --options runtime --timestamp "$APP"
codesign --verify --deep --strict "$APP"
