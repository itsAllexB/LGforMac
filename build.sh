#!/bin/bash
# Builds LGforMac and assembles dist/LGforMac.app (ad-hoc signed).
# Usage: ./build.sh [debug|release] [--run]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="dist/LGforMac.app"

# Generate the app icon once (committed afterwards, regenerated only if missing).
if [[ ! -f Support/AppIcon.icns ]]; then
    echo "Generating app icon…"
    swift scripts/make_icon.swift Support/AppIcon.icns
fi

swift build -c "$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp ".build/$CONFIG/LGforMac" "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/"
cp Support/AppIcon.icns "$APP/Contents/Resources/"
cp Support/com.itsallexb.LGforMac.autostart.plist "$APP/Contents/Library/LaunchAgents/"

# Prefer a stable local signing identity (keeps the macOS Local Network permission
# grant across rebuilds — ad-hoc signatures change identity every build); ad-hoc fallback.
if security find-identity -p codesigning 2>/dev/null | grep -q "LGforMac Local Signing"; then
    codesign --force --sign "LGforMac Local Signing" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built $APP"

if [[ "${2:-}" == "--run" ]]; then
    open "$APP"
fi
