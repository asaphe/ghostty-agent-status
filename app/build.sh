#!/usr/bin/env bash
# Build Ghostty Sidebar, install it as ~/Applications/Ghostty Sidebar.app (ad-hoc signed) and start it.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
app="${HOME}/Applications/Ghostty Sidebar.app"

swift build -c release --package-path "$here"
bin="$(swift build -c release --package-path "$here" --show-bin-path)/GhosttySidebar"

if pgrep -x GhosttySidebar >/dev/null; then
  osascript -e 'tell application id "io.github.asaphe.ghostty-agent-status" to quit'
  for attempt in {1..50}; do
    if ! pgrep -x GhosttySidebar >/dev/null; then break; fi
    sleep 0.1
  done
  if pgrep -x GhosttySidebar >/dev/null; then
    echo "Ghostty Sidebar did not quit; leaving the installed app intact." >&2
    exit 1
  fi
fi
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
if [ -n "${GHOSTTY_SIDEBAR_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$GHOSTTY_SIDEBAR_SIGN_IDENTITY" "$app"
else
  # An ad-hoc signature's default requirement is its cdhash, which orphans the Accessibility grant on every rebuild.
  codesign --force --sign - -r='designated => identifier "io.github.asaphe.ghostty-agent-status"' "$app"
fi
echo "installed: $app"
open "$app"
