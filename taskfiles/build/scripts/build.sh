#!/bin/sh
# Build Token Monitor.app (task build:app).
#
# Usage: sh taskfiles/build/scripts/build.sh [--test] [--build-dir DIR] [--expect-arch arm64|x86_64]
#   --test         Compile the native test launch modes (tests/TestModes.swift) into
#                  build/test; release builds never contain them. Same as TEST_BUILD=1.
#   --build-dir    Output folder (default build, or build/test with --test). Same as BUILD_DIR.
#                  Relative paths resolve from the repository root.
#   --expect-arch  Fail unless this Mac's architecture matches (CI matrix guard).
# Env: APP_VERSION (default VERSION), APP_BUILD (default 1), BUILD_DIR, TEST_BUILD.
set -eu
cd "$(dirname "$0")/../../.."
test_build="${TEST_BUILD:-0}"
build_dir="${BUILD_DIR:-}"
expect_arch=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --test) test_build=1 ;;
    --build-dir) [ "$#" -ge 2 ] || { echo "--build-dir needs a folder" >&2; exit 2; }; build_dir="$2"; shift ;;
    --expect-arch) [ "$#" -ge 2 ] || { echo "--expect-arch needs arm64 or x86_64" >&2; exit 2; }; expect_arch="$2"; shift ;;
    -h|--help) sed -n '2,10p' taskfiles/build/scripts/build.sh; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
case "$test_build" in
  0) build_dir="${build_dir:-$PWD/build}"; set -- ;;
  1) build_dir="${build_dir:-$PWD/build/test}"; set -- -D TOKEN_MONITOR_TESTS tests/TestModes.swift ;;
  *) echo "TEST_BUILD must be 0 or 1" >&2; exit 1 ;;
esac
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd)"
app="$build_dir/Token Monitor.app"
version="${APP_VERSION:-$(cat VERSION)}"
architecture="$(uname -m)"
case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;; esac
if [ -n "$expect_arch" ] && [ "$expect_arch" != "$architecture" ]; then echo "Expected $expect_arch, running on $architecture" >&2; exit 1; fi
mkdir -p "$app/Contents/MacOS"
python3 taskfiles/build/scripts/bundle_info.py "$app" "$version" "${APP_BUILD:-1}"
python3 - "$build_dir" <<'PYBUILD'
import json,sys
from pathlib import Path
root = Path(sys.argv[1])
(root / 'empty.modulemap').write_text('// Project-local compatibility overlay.\n')
legacy = Path('/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap')
new = legacy.with_name('bridging.modulemap')
roots = [{'type': 'file', 'name': str(legacy), 'external-contents': str(root / 'empty.modulemap')}] if legacy.exists() and new.exists() else []
(root / 'toolchain-overlay.json').write_text(json.dumps({'version': 0, 'roots': roots}))
PYBUILD
python3 taskfiles/build/scripts/sparkle.py "$build_dir"
xcrun swiftc -vfsoverlay "$build_dir/toolchain-overlay.json" -Xcc -ivfsoverlay -Xcc "$build_dir/toolchain-overlay.json" taskfiles/build/scripts/key_public.swift -o "$build_dir/sparkle/key_public"
mkdir -p "$app/Contents/Frameworks" "$app/Contents/Resources"
cp "$build_dir/sparkle/LICENSE" "$app/Contents/Resources/SPARKLE-LICENSE"
/usr/bin/ditto "$build_dir/sparkle/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
xcrun swiftc -target "$architecture-apple-macos15.0" -vfsoverlay "$build_dir/toolchain-overlay.json" -Xcc -ivfsoverlay -Xcc "$build_dir/toolchain-overlay.json" -module-cache-path "$build_dir/module-cache" -swift-version 5 -O main.swift Updates.swift "$@" -F "$build_dir/sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$app/Contents/MacOS/TokenMonitor" -framework Cocoa -framework SwiftUI
mkdir -p "$app/Contents/Resources"
cp private_state.py collector.py quotas.py claude_statusline.py install_claude_observer.py "$app/Contents/Resources/"
python3 taskfiles/build/scripts/bundle_python.py "$app/Contents/Resources" "$build_dir/downloads"

codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
