#!/bin/bash
#
# Build Moves for a connected iPhone, install it, and launch it.
#
# Signing identity comes from Config/Moves.xcconfig (override it locally with
# Config/Moves.local.xcconfig), and the bundle ID is read back out of the resolved
# build settings, so this script contains no identifiers of its own.
#
# Requires an Apple ID in Xcode → Settings → Accounts so that automatic signing can
# register the App IDs, App Group, and iCloud container.
#
# Usage:
#   ./Scripts/install-iphone.sh
#   DEVICE_UDID=00008150-000534E2368A401C ./Scripts/install-iphone.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEVICE_UDID="${DEVICE_UDID:-00008150-000534E2368A401C}"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Moves-iphone"
APP="$DERIVED/Build/Products/Debug-iphoneos/Moves.app"

# Ask xcodebuild for the identifier the project will actually produce.
BUNDLE_ID="$(
  xcodebuild -project Moves.xcodeproj -scheme Moves -configuration Debug \
    -destination 'generic/platform=iOS' -showBuildSettings 2>/dev/null |
    awk -F' = ' '/^ *PRODUCT_BUNDLE_IDENTIFIER = /{print $2; exit}'
)"

if [[ -z "$BUNDLE_ID" ]]; then
  echo "error: could not resolve PRODUCT_BUNDLE_IDENTIFIER from the project" >&2
  exit 1
fi

echo "Building ${BUNDLE_ID} for device ${DEVICE_UDID}..."
xcodebuild -project Moves.xcodeproj -scheme Moves -configuration Debug \
  -destination "platform=iOS,id=${DEVICE_UDID}" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -derivedDataPath "$DERIVED" \
  build

echo "Installing ${APP} on ${DEVICE_UDID}..."
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP"

echo "Launching ${BUNDLE_ID}..."
if ! xcrun devicectl device process launch --device "$DEVICE_UDID" --terminate-existing --activate "$BUNDLE_ID"; then
  echo "Install succeeded but launch failed. Unlock the iPhone and run:" >&2
  echo "  xcrun devicectl device process launch --device ${DEVICE_UDID} --terminate-existing --activate ${BUNDLE_ID}" >&2
  exit 2
fi
