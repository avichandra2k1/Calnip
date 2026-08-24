#!/bin/zsh
# Release build: universal binary, Developer ID + hardened runtime, notarized.
#
# One-time setup:
#   1. Xcode > Settings > Accounts > (personal team G8JVK5GZAM) >
#      Manage Certificates > + > Developer ID Application
#   2. xcrun notarytool store-credentials calnip-notary \
#        --apple-id avichandra2k1@gmail.com --team-id G8JVK5GZAM \
#        --password <app-specific password from appleid.apple.com>
set -e
cd "$(dirname "$0")"

TEAM_ID="G8JVK5GZAM"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
ZIP="Calnip-$VERSION.zip"

SIGN_ID=$(security find-identity -p codesigning -v \
  | awk -F'"' -v team="$TEAM_ID" '$0 ~ /Developer ID Application/ && $0 ~ team {print $2; exit}')
if [[ -z "$SIGN_ID" ]]; then
  echo "error: no 'Developer ID Application' certificate for team $TEAM_ID in keychain." >&2
  echo "Create one in Xcode > Settings > Accounts (personal team) > Manage Certificates." >&2
  exit 1
fi

echo "Building universal binary…"
swift build -c release --arch arm64 --arch x86_64

APP=Calnip.app
rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS"
cp .build/apple/Products/Release/Calnip "$APP/Contents/MacOS/Calnip"
cp Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  mkdir -p "$APP/Contents/Resources"
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi

echo "Signing as: $SIGN_ID"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"

if xcrun notarytool history --keychain-profile calnip-notary >/dev/null 2>&1; then
  echo "Notarizing (this takes a few minutes)…"
  xcrun notarytool submit "$ZIP" --keychain-profile calnip-notary --wait
  echo "Stapling…"
  xcrun stapler staple "$APP"
  rm "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl -a -vv "$APP"
else
  echo "note: notary profile 'calnip-notary' not found; skipped notarization." >&2
fi

echo ""
echo "Done: $ZIP"
echo "Next:"
echo "  git tag v$VERSION && git push origin v$VERSION"
echo "  gh release create v$VERSION $ZIP --title \"Calnip $VERSION\""
echo "  shasum -a 256 $ZIP   # update sha256 + version in the tap's Casks/calnip.rb"
