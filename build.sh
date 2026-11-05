#!/bin/zsh
# Builds HueBar.app into ./build. Pass --install to copy it to /Applications and relaunch it.
set -euo pipefail
cd "${0:A:h}"

swift build -c release
APP=build/HueBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/HueBar "$APP/Contents/MacOS/HueBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x HueBar 2>/dev/null && sleep 1 || true
    rm -rf /Applications/HueBar.app
    ditto "$APP" /Applications/HueBar.app
    open /Applications/HueBar.app
    echo "installed /Applications/HueBar.app"
fi
