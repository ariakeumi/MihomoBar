#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-MihomoBar}"
BUNDLE_ID="${BUNDLE_ID:-com.mihomobar}"
APP_VERSION="${APP_VERSION:-0.2.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
TARGET_ARCH="${TARGET_ARCH:-}"
PREPROCESS_DIR="${PREPROCESS_DIR:-$ROOT/dist/preprocess}"
PREPROCESSED_ICON_PATH="${PREPROCESSED_ICON_PATH:-$PREPROCESS_DIR/${APP_NAME}.icns}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-MihomoBar}"
RESOURCE_BUNDLE_NAME="${RESOURCE_BUNDLE_NAME:-ClashBar_ClashBar.bundle}"

APP="$ROOT/dist/${APP_NAME}.app"

cd "$ROOT"

BUILD_ARGS=(-c release)
if [ -n "$TARGET_ARCH" ]; then
  BUILD_ARGS+=(--arch "$TARGET_ARCH")
fi
swift build "${BUILD_ARGS[@]}"

if [ -n "$TARGET_ARCH" ]; then
  BIN_CANDIDATE="$ROOT/.build/${TARGET_ARCH}-apple-macosx/release/${EXECUTABLE_NAME}"
  RESOURCE_BUNDLE_CANDIDATE="$ROOT/.build/${TARGET_ARCH}-apple-macosx/release/${RESOURCE_BUNDLE_NAME}"
  BIN_PATTERN="*/${TARGET_ARCH}-apple-macosx/release/${EXECUTABLE_NAME}"
  RESOURCE_BUNDLE_PATTERN="*/${TARGET_ARCH}-apple-macosx/release/${RESOURCE_BUNDLE_NAME}"
else
  BIN_CANDIDATE="$ROOT/.build/release/${EXECUTABLE_NAME}"
  RESOURCE_BUNDLE_CANDIDATE="$ROOT/.build/release/${RESOURCE_BUNDLE_NAME}"
  BIN_PATTERN="*/release/${EXECUTABLE_NAME}"
  RESOURCE_BUNDLE_PATTERN="*/release/${RESOURCE_BUNDLE_NAME}"
fi

resolve_build_artifact() {
  local candidate="$1"
  local artifact_type="$2"
  local release_pattern="$3"

  if [ "$artifact_type" = "file" ] && [ -f "$candidate" ]; then
    echo "$candidate"
    return
  fi
  if [ "$artifact_type" = "dir" ] && [ -d "$candidate" ]; then
    echo "$candidate"
    return
  fi

  local find_type="f"
  if [ "$artifact_type" = "dir" ]; then
    find_type="d"
  fi
  find "$ROOT/.build" -path "$release_pattern" -type "$find_type" | head -n 1 || true
}

BIN="$(resolve_build_artifact "$BIN_CANDIDATE" file "$BIN_PATTERN")"
RESOURCE_BUNDLE="$(resolve_build_artifact "$RESOURCE_BUNDLE_CANDIDATE" dir "$RESOURCE_BUNDLE_PATTERN")"

if [ ! -f "$BIN" ]; then
  echo "Build output not found: $BIN" >&2
  exit 1
fi
if [ ! -d "$RESOURCE_BUNDLE" ]; then
  echo "Resource bundle not found: $RESOURCE_BUNDLE" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/${EXECUTABLE_NAME}"
chmod +x "$APP/Contents/MacOS/${EXECUTABLE_NAME}"

rm -rf "$APP/Contents/Resources/${RESOURCE_BUNDLE_NAME}"
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/${RESOURCE_BUNDLE_NAME}"

ICON_PLIST_ENTRY=""
if [ -f "$PREPROCESSED_ICON_PATH" ]; then
  cp "$PREPROCESSED_ICON_PATH" "$APP/Contents/Resources/${APP_NAME}.icns"
  ICON_PLIST_ENTRY="<key>CFBundleIconFile</key><string>${APP_NAME}.icns</string>"
else
  echo "Warning: preprocessed icon not found at $PREPROCESSED_ICON_PATH"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>${APP_NAME}</string>
<key>CFBundleDisplayName</key><string>${APP_NAME}</string>
<key>CFBundleExecutable</key><string>${EXECUTABLE_NAME}</string>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
<key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
$ICON_PLIST_ENTRY
<key>NSAppTransportSecurity</key>
<dict>
<key>NSAllowsArbitraryLoads</key><true/>
</dict>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign "$CODESIGN_IDENTITY" "$APP"
fi

echo "Built app: $APP"
