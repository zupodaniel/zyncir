#!/usr/bin/env bash
#
# Builds the "Share to zyncir" companion APK (com.zyncir.share) with no Gradle:
# javac -> d8 -> aapt2 link -> add dex -> zipalign -> apksigner. Requires the
# Android SDK with platform android-35 and build-tools 35.0.0, plus a JDK.
#
set -euo pipefail

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
# Compile/target API 36; build-tools 35.0.0 is the newest installed and targets
# 36 fine (build-tools need not match compileSdk).
PLATFORM="$SDK/platforms/android-36"
BUILD_TOOLS="$SDK/build-tools/35.0.0"
ANDROID_JAR="$PLATFORM/android.jar"
AAPT2="$BUILD_TOOLS/aapt2"
D8="$BUILD_TOOLS/d8"
ZIPALIGN="$BUILD_TOOLS/zipalign"
APKSIGNER="$BUILD_TOOLS/apksigner"
MIN_API=29
TARGET_API=36

DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/src"
BUILD="$DIR/build"
CLASSES="$BUILD/classes"
KEYSTORE="$DIR/zyncir-debug.keystore"

for tool in "$ANDROID_JAR" "$AAPT2" "$D8" "$ZIPALIGN" "$APKSIGNER"; do
    [ -e "$tool" ] || { echo "Missing Android build tool: $tool" >&2; exit 1; }
done

rm -rf "$BUILD"
mkdir -p "$CLASSES"

echo "==> Compiling Java sources"
SOURCES=$(find "$SRC" -name '*.java')
javac -source 8 -target 8 -nowarn -classpath "$ANDROID_JAR" -d "$CLASSES" $SOURCES

echo "==> Dexing with d8"
CLASS_FILES=$(find "$CLASSES" -name '*.class')
"$D8" --min-api "$MIN_API" --lib "$ANDROID_JAR" --output "$BUILD" $CLASS_FILES

echo "==> Compiling resources (aapt2)"
"$AAPT2" compile --dir "$DIR/res" -o "$BUILD/res.zip"

echo "==> Linking manifest + resources into APK (aapt2)"
"$AAPT2" link \
    -o "$BUILD/base.apk" \
    -I "$ANDROID_JAR" \
    --manifest "$DIR/AndroidManifest.xml" \
    --min-sdk-version "$MIN_API" \
    --target-sdk-version "$TARGET_API" \
    "$BUILD/res.zip"

echo "==> Adding classes.dex"
( cd "$BUILD" && zip -q base.apk classes.dex )

echo "==> Zipaligning"
"$ZIPALIGN" -f -p 4 "$BUILD/base.apk" "$BUILD/aligned.apk"

if [ ! -f "$KEYSTORE" ]; then
    echo "==> Creating debug keystore"
    keytool -genkeypair -v -keystore "$KEYSTORE" -storepass android -keypass android \
        -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=zyncir Debug, O=zyncir, C=US"
fi

echo "==> Signing (apksigner)"
"$APKSIGNER" sign --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
    --out "$BUILD/zyncir-share.apk" "$BUILD/aligned.apk"

rm -f "$BUILD/base.apk" "$BUILD/aligned.apk" "$BUILD/aligned.apk.idsig"
echo "Done: $BUILD/zyncir-share.apk"
