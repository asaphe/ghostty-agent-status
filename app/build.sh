#!/usr/bin/env bash
# Build Ghostty Sidebar, install it as ~/Applications/Ghostty Sidebar.app (ad-hoc signed) and start it.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
app="${HOME}/Applications/Ghostty Sidebar.app"

swift build -c release --package-path "$here"
bin="$(swift build -c release --package-path "$here" --show-bin-path)/GhosttySidebar"

pkill -x GhosttySidebar 2>/dev/null || true
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/GhosttySidebar"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.asaphe.ghostty-agent-status</string>
  <key>CFBundleName</key><string>Ghostty Sidebar</string>
  <key>CFBundleExecutable</key><string>GhosttySidebar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Focus the Ghostty terminal of the session you click.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "installed: $app"
open "$app"
