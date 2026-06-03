#!/usr/bin/env bash
# Build the zyncir device helper into a dex-bearing jar (no Gradle).
#
#   ./build.sh         # produces build/zyncir.jar
#
# Requires the Android SDK (ANDROID_HOME / ANDROID_SDK_ROOT or the default
# ~/Library/Android/sdk) with platform android-35 and build-tools 35.0.0.
set -euo pipefail

cd "$(dirname "$0")"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
PLATFORM="$SDK/platforms/android-35"
BUILD_TOOLS="$SDK/build-tools/35.0.0"
ANDROID_JAR="$PLATFORM/android.jar"
D8="$BUILD_TOOLS/d8"
MIN_API=35

[ -f "$ANDROID_JAR" ] || { echo "android.jar not found at $ANDROID_JAR" >&2; exit 1; }
[ -x "$D8" ] || { echo "d8 not found at $D8" >&2; exit 1; }

OUT="build"
CLASSES="$OUT/classes"
rm -rf "$OUT"
mkdir -p "$CLASSES"

echo "==> Compiling Java sources against $ANDROID_JAR"
SOURCES=$(find src -name '*.java')
# android.jar is on the classpath (provides android.*); the JDK supplies java.*
# (including java.lang.invoke.LambdaMetafactory needed to compile lambdas and
# method references). Target Java 8 bytecode; d8 desugars lambdas afterwards.
# The "bootstrap class path not set" note is expected and harmless.
javac -source 8 -target 8 -nowarn \
  -classpath "$ANDROID_JAR" \
  -d "$CLASSES" \
  $SOURCES

echo "==> Dexing with d8 (min-api $MIN_API)"
CLASS_FILES=$(find "$CLASSES" -name '*.class')
"$D8" --min-api "$MIN_API" --lib "$ANDROID_JAR" --output "$OUT" $CLASS_FILES

echo "==> Packaging build/zyncir.jar"
( cd "$OUT" && jar cf zyncir.jar classes.dex )

echo "Done: $OUT/zyncir.jar"
