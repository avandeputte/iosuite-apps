#!/bin/zsh
# Builds the iPhone/iPad app and uploads it to TestFlight, the same way as iopix's tools/testflight.sh.
# Needs an App Store Connect API key: ASC_KEY_ID, ASC_ISSUER_ID and the key file at
# ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8 (the key never goes in this repo), and the app
# (bundle id net.iothing.ionotes) created in App Store Connect. The build number is the time of the build,
# so every upload is newer.
set -euo pipefail
cd "${0:A:h}/.."
: "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
KEY=~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8
[[ -f $KEY ]] || { echo "No key file at $KEY"; exit 1; }
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
BUILD=$(date -u +%Y%m%d%H%M)
ARCHIVE=build/ionotes-ios-$BUILD.xcarchive
xcodegen generate -q
xcodebuild -project ionotes.xcodeproj -scheme ionotesiOS -configuration Release -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" CURRENT_PROJECT_VERSION=$BUILD "${AUTH[@]}" archive
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist tools/ExportOptions-TestFlight.plist \
  -exportPath build/export-ios-$BUILD "${AUTH[@]}"
echo "Uploaded build $BUILD. It shows in App Store Connect › TestFlight after Apple has processed it."
