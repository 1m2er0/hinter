#!/bin/sh
# Builds build/HinterHind.app. Uses Xcode toolchain (CLT lacks Swift Testing/new SDK bits).
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release
APP=build/HinterHind.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/HinterHind "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# A stable certificate keeps macOS permissions and Keychain "Always Allow" across rebuilds;
# ad-hoc signing changes the code hash every build, so macOS treats each build as a new app.
ID="${HH_SIGN_ID:-HinterHind}"
if security find-identity -p codesigning | grep -q "\"$ID\""; then  # self-signed is "not trusted" but signs fine
    codesign -s "$ID" --force --identifier com.hinterhind.app "$APP"
else
    echo "warning: no '$ID' code-signing certificate; ad-hoc signing — permissions will be asked again after each rebuild" >&2
    codesign -s - --force "$APP"
fi
echo "$APP"
