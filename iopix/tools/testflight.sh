#!/bin/zsh
# Builds the iPhone app (or, with `tvos`, the Apple TV app) and uploads it to TestFlight.
# Needs a paid Apple Developer team in project.yml and an App Store Connect API key:
#   ASC_KEY_ID, ASC_ISSUER_ID and the key file at ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
# (the key never goes in this repo). The build number is the time of the build, so every upload is newer.
set -euo pipefail
cd "${0:A:h}/.."
: "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
KEY=~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8
[[ -f $KEY ]] || { echo "No key file at $KEY"; exit 1; }
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
BUILD=$(date -u +%Y%m%d%H%M)
PLATFORM=${1:-ios}
case $PLATFORM in
  ios) SCHEME=iopix DEST="generic/platform=iOS" EXTRA=() ;;
  tvos) SCHEME=iopixTV DEST="generic/platform=tvOS" EXTRA=(CODE_SIGNING_ALLOWED=NO) ;;  # no Apple TV registered for development signing: the export signs it for distribution
  *) echo "usage: $0 [ios|tvos]"; exit 1 ;;
esac
ARCHIVE=build/iopix-$PLATFORM-$BUILD.xcarchive
xcodegen generate -q
xcodebuild -project iopix.xcodeproj -scheme $SCHEME -configuration Release -destination "$DEST" \
  -archivePath "$ARCHIVE" CURRENT_PROJECT_VERSION=$BUILD "${EXTRA[@]}" "${AUTH[@]}" archive
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist tools/ExportOptions-TestFlight.plist \
  -exportPath build/export-$PLATFORM-$BUILD "${AUTH[@]}"
echo "Uploaded build $BUILD. It shows in App Store Connect › TestFlight after Apple has processed it."
