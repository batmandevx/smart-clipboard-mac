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

# Ad-hoc signatures change with every build, and macOS ties Screen Recording permission to the signature, so a
# rebuilt app would lose its permission. Pinning the requirement to the bundle id keeps the grant across rebuilds.
# Pinning the requirement alone isn't reliable: TCC still tracks ad-hoc apps by their per-build hash.
# A stable certificate (see scripts/make-signing-cert.sh) keeps the permission across rebuilds.
IDENTITY="ClipStack Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "warning: '$IDENTITY' not found — ad-hoc signing; Screen Recording permission may reset on rebuild."
    echo "         Run ./scripts/make-signing-cert.sh once to fix this."
    codesign --force --deep --sign - -r='designated => identifier "com.ayush.clipstack"' "$APP"
fi
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
    pkill -x ClipStack 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/ClipStack.app
    cp -R "$APP" /Applications/
    open /Applications/ClipStack.app
    echo "Installed to /Applications and launched."
fi

