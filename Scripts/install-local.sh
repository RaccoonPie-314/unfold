#!/usr/bin/env bash
# Build, sign with the stable local identity, install to ~/Applications, relaunch.
#
# The accessibility grant macOS remembers is keyed to the signing identity. Ad-hoc signing makes that
# identity the build hash, so every rebuild looked like a new app and demanded a new grant. Signing
# with "Unfold Dev Signing" (a self-signed, code-signing-only certificate in the login keychain) keeps
# the identity stable, so the grant survives rebuilds.
set -euo pipefail

APP_NAME="Unfold"
IDENTITY="${UNFOLD_SIGN_IDENTITY:-Unfold Dev Signing}"
CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$HOME/Applications/$APP_NAME.app"

cd "$ROOT"
swift build -c "$CONFIG"

pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/$CONFIG/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --entitlements "$ROOT/Resources/$APP_NAME.entitlements" "$APP"
  echo "signed with '$IDENTITY' — the accessibility grant survives the next rebuild"
else
  echo "warning: signing identity '$IDENTITY' not found; falling back to ad-hoc" >&2
  echo "warning: macOS will treat every rebuild as a new app and ask for access again" >&2
  codesign --force --sign - --entitlements "$ROOT/Resources/$APP_NAME.entitlements" "$APP"
fi

open "$APP"
echo "installed: $APP"

# The .build bundle shares this bundle identifier and confuses app-launching tools with an ambiguous
# match; the installed copy is the only one that should exist.
rm -rf "$ROOT/.build/$CONFIG/$APP_NAME.app" "$ROOT/.build/out/Products/$([ "$CONFIG" = "debug" ] && echo Debug || echo Release)/$APP_NAME.app" 2>/dev/null || true
