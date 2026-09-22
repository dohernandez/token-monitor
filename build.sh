#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="$PWD/build/Token Monitor.app"
mkdir -p "$app/Contents/MacOS"
python3 - <<'PYBUILD'
import json
from pathlib import Path
root = Path.cwd()
(root / 'build/empty.modulemap').write_text('// Project-local compatibility overlay.\n')
legacy = Path('/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap')
new = legacy.with_name('bridging.modulemap')
roots = [{'type': 'file', 'name': str(legacy), 'external-contents': str(root / 'build/empty.modulemap')}] if legacy.exists() and new.exists() else []
(root / 'build/toolchain-overlay.json').write_text(json.dumps({'version': 0, 'roots': roots}))
PYBUILD
xcrun swiftc -vfsoverlay "$PWD/build/toolchain-overlay.json" -Xcc -ivfsoverlay -Xcc "$PWD/build/toolchain-overlay.json" -module-cache-path "$PWD/build/module-cache" -swift-version 5 -O main.swift -o "$app/Contents/MacOS/TokenMonitor" -framework Cocoa -framework SwiftUI
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TokenMonitor</string>
<key>CFBundleIdentifier</key><string>local.darien.tokenmonitor</string>
<key>CFBundleName</key><string>Token Monitor</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
mkdir -p "$app/Contents/Resources"
cp collector.py quotas.py "$app/Contents/Resources/"
codesign --force --sign - "$app"
printf '%s\n' "$app"
