#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"; fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/cache"
xcrun swift build -c release --disable-sandbox
PATTERN_RECORDER_DESTINATION="${PATTERN_RECORDER_OUTPUT_DIR:-$PWD/dist}"
mkdir -p "$PATTERN_RECORDER_DESTINATION"
APP="$PATTERN_RECORDER_DESTINATION/Pattern Recorder.app"
# Recreate generated bundle so old Finder metadata/signatures cannot break repeat builds.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp -X .build/release/PatternRecorder "$APP/Contents/MacOS/PatternRecorder"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.gavinzdarko.PatternRecorder</string>
<key>CFBundleName</key><string>Pattern Recorder</string>
<key>CFBundleExecutable</key><string>PatternRecorder</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Ad-hoc local signature. Set SIGN_IDENTITY to a Developer ID identity for stable distribution.
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP (not launched; capture remains OFF)"
