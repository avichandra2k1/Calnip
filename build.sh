#!/bin/zsh
# Builds Calnip.app — a proper bundle is required for the calendar permission prompt.
set -e
cd "$(dirname "$0")"

swift build -c release

APP=Calnip.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Calnip "$APP/Contents/MacOS/Calnip"
cp Info.plist "$APP/Contents/Info.plist"
# Stable identity keeps the calendar permission grant across rebuilds
# (ad-hoc "-" changes cdhash every build and re-triggers the TCC prompt).
SIGN_ID=$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --sign "${SIGN_ID:--}" "$APP"

echo "Built $APP — launch with: open $APP"
