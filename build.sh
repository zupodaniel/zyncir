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

echo
echo "Done."
echo "  Helper jar : android-helper/build/zyncir.jar"
echo "  Mac binary : mac-app/.build/release/zyncird"
