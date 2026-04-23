#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/easyRun.xcodeproj}"
SCHEME="${SCHEME:-easyRun}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-easyRun}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build/package-test}"
DERIVED_DATA_PATH="$BUILD_ROOT/DerivedData"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build/distribution}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
ZIP_PATH="$OUTPUT_DIR/$APP_NAME-test.zip"

mkdir -p "$BUILD_ROOT" "$OUTPUT_DIR"

echo "==> Building $SCHEME ($CONFIGURATION)"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle was not found at: $APP_PATH" >&2
  exit 1
fi

echo "==> Ad-hoc signing $APP_PATH"
codesign --force --deep --sign - --timestamp=none "$APP_PATH"

echo "==> Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Gatekeeper assessment"
if spctl -a -vv --type execute "$APP_PATH"; then
  echo "Gatekeeper accepted the app."
else
  echo "Gatekeeper rejected this ad-hoc build as expected without Developer ID notarization."
  echo "Trusted testers can Control-click the app and choose Open, or remove quarantine after unzipping."
fi

echo "==> Creating zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Package created"
ls -lh "$ZIP_PATH"
echo
echo "Tester note:"
echo "  1. Unzip $APP_NAME-test.zip."
echo "  2. Move $APP_NAME.app to /Applications."
echo "  3. Control-click $APP_NAME.app and choose Open."
