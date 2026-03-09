#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-MihomoBar}"
PREPROCESS_DIR="${PREPROCESS_DIR:-$ROOT/dist/preprocess}"
ICON_SOURCE="$ROOT/Sources/ClashBar/Resources/Brand/mihomobar.icns"
PREPROCESSED_ICON_PATH="$PREPROCESS_DIR/${APP_NAME}.icns"

mkdir -p "$PREPROCESS_DIR"

prepare_icon() {
  if [ ! -f "$ICON_SOURCE" ]; then
    echo "Warning: app icon source not found at $ICON_SOURCE"
    return
  fi
  cp "$ICON_SOURCE" "$PREPROCESSED_ICON_PATH"
  echo "Prepared app icon: $PREPROCESSED_ICON_PATH"
}

prepare_icon
