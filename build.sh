#!/usr/bin/env bash
# Build everything: the Android helper jar, then the macOS app (with the jar
# embedded as a resource).
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building Android helper"
( cd android-helper && ./build.sh )

echo "==> Embedding helper jar into the macOS app resources"
cp android-helper/build/zyncir.jar mac-app/Sources/zyncird/Resources/zyncir.jar

echo "==> Building macOS app"
( cd mac-app && swift build -c release )

# Assemble a real .app bundle. This is required (not cosmetic): macOS Local
# Network Privacy only grants LAN access to a code-signed app with a stable
# identity and an NSLocalNetworkUsageDescription. The bare executable can never
# be authorized, so wireless adb (adb connect) is silently blocked. As a bundled,
# signed app, zyncir is the "responsible" process for the adb server it spawns,
# so adb's connections inherit zyncir's Local Network grant.
echo "==> Assembling zyncir.app"
REL="mac-app/.build/release"
APP="$REL/zyncir.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$REL/zyncird" "$APP/Contents/MacOS/zyncird"
# Bundle.module finds zyncir.jar via this SwiftPM resource bundle. In an .app it
# must live in Contents/Resources (Bundle.main.resourceURL, the first path the
# generated accessor checks) — and codesign only accepts nested bundles there.
cp -R "$REL/zyncird_zyncird.bundle" "$APP/Contents/Resources/zyncird_zyncird.bundle"
cp mac-app/packaging/Info.plist "$APP/Contents/Info.plist"
cp mac-app/packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> Code-signing (stable identity so the Local Network grant persists)"
# Default to the personal Apple Development identity; override with CODESIGN_ID.
CODESIGN_ID="${CODESIGN_ID:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Apple Development: Daniel Zupo \(/{print $2; exit}')}"
if [ -z "$CODESIGN_ID" ]; then
    echo "ERROR: no 'Apple Development: Daniel Zupo' signing identity found." >&2
    echo "       Set CODESIGN_ID to a valid identity and re-run." >&2
    exit 1
fi
echo "    identity: $CODESIGN_ID"
codesign --force --options runtime \
    --entitlements mac-app/packaging/zyncir.entitlements \
    --sign "$CODESIGN_ID" "$APP"
codesign --verify --strict "$APP"

echo
echo "Done."
echo "  Helper jar : android-helper/build/zyncir.jar"
echo "  Mac app    : $APP"
