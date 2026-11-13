#!/bin/zsh
# Builds ioStart for iPhone and iPad and uploads it to TestFlight, the same way as ionote-apps' tools/testflight.sh.
# Signs in with Xcode's own account (Xcode › Settings › Accounts), or with an App Store Connect API key when
# ASC_KEY_ID and ASC_ISSUER_ID are set (key file at ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8, never in
# this repo). The app (bundle id net.iothing.iostart) must exist in App Store Connect. The build number is the time
# of the build, so every upload is newer.
set -euo pipefail
cd "${0:A:h}/.."
AUTH=(-allowProvisioningUpdates)
if [[ -n ${ASC_KEY_ID:-} ]]; then
  : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID too}"
  KEY=~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8
  [[ -f $KEY ]] || { echo "No key file at $KEY"; exit 1; }
  AUTH+=(-authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
BUILD=$(date -u +%Y%m%d%H%M)
ARCHIVE=build/ioStart-$BUILD.xcarchive
xcodegen generate -q
xcodebuild -project ioStart.xcodeproj -scheme ioStart -configuration Release -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" CURRENT_PROJECT_VERSION=$BUILD "${AUTH[@]}" archive
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist tools/ExportOptions-TestFlight.plist \
  -exportPath build/export-$BUILD "${AUTH[@]}"
echo "Uploaded build $BUILD. It shows in App Store Connect › TestFlight after Apple has processed it."
