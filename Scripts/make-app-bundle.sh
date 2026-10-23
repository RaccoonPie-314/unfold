#!/usr/bin/env bash
# Assembles a runnable Unfold.app from the SwiftPM build product, because this
# machine has Command Line Tools only and cannot drive xcodebuild.
set -euo pipefail

APP_NAME="Unfold"
CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

cd "$ROOT"
swift build -c "$CONFIG"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Ad-hoc signature. TCC grants Accessibility against the signature, so every
# rebuild here resets the permission toggle. Use `./Scripts/make-app-bundle.sh release`
# with a real Developer ID once distribution starts.
codesign --force --sign - \
  --entitlements "$ROOT/Resources/$APP_NAME.entitlements" \
  "$APP_DIR"

open "$APP_DIR"
echo "$APP_DIR"
