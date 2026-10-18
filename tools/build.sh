#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
APP="$PWD/.build/MacroPad.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -module-cache-path .build/module-cache Sources/**/*.swift -o "$APP/Contents/MacOS/MacroPad" -framework AppKit -framework SwiftUI -framework IOKit -framework CoreAudio -framework ApplicationServices -framework WebKit
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacroPad</string>
<key>CFBundleIdentifier</key><string>nl.theredhead.msd-two</string>
<key>CFBundleName</key><string>MacroPad</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Run AppleScript actions configured for your macro pad.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
