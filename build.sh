#!/bin/bash
# Builds ClipStack.app. Run `./build.sh install` to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/ClipStack.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/ClipStack" "$APP/Contents/MacOS/ClipStack"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
    pkill -x ClipStack 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/ClipStack.app
    cp -R "$APP" /Applications/
    open /Applications/ClipStack.app
    echo "Installed to /Applications and launched."
fi

