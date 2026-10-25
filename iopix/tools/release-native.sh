#!/bin/zsh
# Builds iopix Native (the iPhone/iPad app as a Mac app, Mac Catalyst) signed with your Developer ID, has Apple notarize it, and makes a disk image that opens
# on any Mac without warnings. Needs the paid team in project.yml and the same App Store Connect API key as
# tools/testflight.sh (ASC_KEY_ID, ASC_ISSUER_ID, ~/.appstoreconnect/private_keys/AuthKey_<id>.p8).
set -euo pipefail
cd "${0:A:h}/.."
: "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
KEY=~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8
[[ -f $KEY ]] || { echo "No key file at $KEY"; exit 1; }
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
BUILD=$(date -u +%Y%m%d%H%M)
VERSION=$(grep -m1 MARKETING_VERSION project.yml | grep -oE '[0-9.]+')
ARCHIVE=build/iopix-native-$BUILD.xcarchive OUT=build/native-$BUILD DMG="build/iopix-Native-$VERSION.dmg"
xcodegen generate -q
xcodebuild -project iopix.xcodeproj -scheme iopix -configuration Release -destination "generic/platform=macOS,variant=Mac Catalyst" -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION=$BUILD "${AUTH[@]}" archive
# the export uses Xcode's signed-in account: it makes the Developer ID profile iCloud needs, which the API key
# is not allowed to do ("Cloud signing permission error")
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist tools/ExportOptions-DeveloperID.plist \
  -exportPath "$OUT" -allowProvisioningUpdates
rm -f "$DMG"
mkdir -p "$OUT/dmg" && cp -R "$OUT/iopix Native.app" "$OUT/dmg/" && ln -sf /Applications "$OUT/dmg/Applications"
hdiutil create -volname "iopix Native" -srcfolder "$OUT/dmg" -ov -format UDZO "$DMG"
codesign --sign "Developer ID Application: Alexandre Van de Putte (69M2JRAT8P)" --timestamp "$DMG"  # a signed image passes Gatekeeper as a whole
xcrun notarytool submit "$DMG" --key "$KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo "Ready to share: $DMG"
