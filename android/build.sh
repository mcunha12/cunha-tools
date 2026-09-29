#!/bin/zsh
# Builds build/android/cunha-companion.apk without Gradle: aapt2 compile/link, javac, d8, zipalign, apksigner.
# The signing keystore lives outside git (~/.android/cunhatools.keystore) and is created on the first run.
set -euo pipefail

HERE="${0:A:h}"
ROOT="${HERE:h}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
TOOLS="$SDK/build-tools/35.0.0"
PLATFORM="$SDK/platforms/android-35/android.jar"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export PATH="$JAVA_HOME/bin:$PATH"
KEYSTORE="${CUNHA_KEYSTORE:-$HOME/.android/cunhatools.keystore}"
STOREPASS="${CUNHA_KEYSTORE_PASS:-cunhatools}"
WORK="$HERE/build"
OUT="$ROOT/build/android"
APK="$OUT/cunha-companion.apk"

rm -rf "${WORK:?}"
mkdir -p "$WORK/classes" "$WORK/dex" "$WORK/gen" "$OUT"

if [[ ! -f "$KEYSTORE" ]]; then
  mkdir -p "${KEYSTORE:h}"
  keytool -genkeypair -keystore "$KEYSTORE" -storepass "$STOREPASS" -keypass "$STOREPASS" -alias cunhatools \
    -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Cunha Tools, O=Marcelo Cunha" >&2
  chmod 600 "$KEYSTORE"
fi

"$TOOLS/aapt2" compile --dir "$HERE/app/res" -o "$WORK/res.zip"
"$TOOLS/aapt2" link -I "$PLATFORM" --manifest "$HERE/app/AndroidManifest.xml" \
  --min-sdk-version 30 --target-sdk-version 35 --version-code 1 --version-name 0.1.0 \
  --java "$WORK/gen" -o "$WORK/base.apk" "$WORK/res.zip"

javac -source 8 -target 8 -bootclasspath "$PLATFORM:$TOOLS/core-lambda-stubs.jar" -Xlint:all -Xlint:-options -encoding UTF-8 -d "$WORK/classes" \
  $(find "$HERE/core/src" "$HERE/app/src" "$WORK/gen" -name '*.java')
jar cf "$WORK/classes.jar" -C "$WORK/classes" .
"$TOOLS/d8" --release --min-api 30 --lib "$PLATFORM" --output "$WORK/dex" "$WORK/classes.jar"

cp "$WORK/base.apk" "$WORK/unsigned.apk"
(cd "$WORK/dex" && zip -q -X -9 "$WORK/unsigned.apk" classes.dex)
"$TOOLS/zipalign" -f -p 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
"$TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-pass "pass:$STOREPASS" --ks-key-alias cunhatools --out "$APK" "$WORK/aligned.apk"
"$TOOLS/apksigner" verify "$APK" >&2
rm -f "$APK.idsig"
# dist/android keeps a ready-to-install copy in the repo, for installing by hand on the phone.
mkdir -p "$ROOT/dist/android"
cp "$APK" "$ROOT/dist/android/cunha-companion.apk"
echo "$APK"
