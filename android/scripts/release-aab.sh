#!/usr/bin/env bash
# Build the Play-ready PocketDJ Android release (release plan A1/A3).
#
#   android/scripts/release-aab.sh [OUT_DIR]
#
# Produces, in OUT_DIR (default android/build/release-out):
#   PocketDJ-<ver>-<code>.aab        signed with the UPLOAD key   -> Play Console upload
#   PocketDJ-<ver>-<code>.apk        universal APK signed with the APP-SIGNING key (same signature
#                                    Play serves) -> sideload / adb install
#   SHA256SUMS, mapping-<code>.txt (R8), native-alignment.txt
#
# Inputs (never commit these):
#   ~/.config/pocketdj/android-signing/{pocketdj-upload.p12 (alias upload), pocketdj-appsigning.p12 (alias pocketdj)}
#   ~/.config/pocketdj/android-signing/passwords.env  (ANDROID_UPLOAD_STORE_PASS, ANDROID_APPSIGN_STORE_PASS)
# Env overrides: VERSION_CODE (default: Unix time, same scheme as apple/scripts/testflight.sh BUILD_NUMBER),
#   VERSION_NAME (default 1.0.0), PDJ_ANDROID_SIGNING_DIR, GRADLE_EXTRA_ARGS.
# Never run two release scripts at once (the lock below enforces it for this script).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${1:-$ANDROID_DIR/build/release-out}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
KEYDIR="${PDJ_ANDROID_SIGNING_DIR:-$HOME/.config/pocketdj/android-signing}"
UPLOAD_P12="$KEYDIR/pocketdj-upload.p12"
APPSIGN_P12="$KEYDIR/pocketdj-appsigning.p12"
VERSION_CODE="${VERSION_CODE:-$(date +%s)}"
VERSION_NAME="${VERSION_NAME:-1.0.0}"

# Pinned certificate SHA-256s (public; from $KEYDIR/fingerprints.txt, 2026-10-29).
APPSIGN_SHA256="26c3cd8f7f56a28bf0f6e9479a05a97a7216bd5d768109e6805e0650dc4cd674"
UPLOAD_SHA256="8ce2a369c7bae04e6457c61f466399d67ee31d7d0dd324e49016002932af5227"

BT="$(ls -d "$ANDROID_HOME"/build-tools/* | sort -V | tail -1)"
READELF="$(ls "$ANDROID_HOME"/ndk/*/toolchains/llvm/prebuilt/*/bin/llvm-readelf | sort -V | tail -1)"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------------------------
[[ -x "$JAVA_HOME/bin/java" ]] || die "JAVA_HOME=$JAVA_HOME has no java"
[[ -f "$UPLOAD_P12" && -f "$APPSIGN_P12" ]] || die "keystores missing in $KEYDIR"
[[ -f "$KEYDIR/passwords.env" ]] || die "$KEYDIR/passwords.env missing"
[[ "$VERSION_CODE" =~ ^[0-9]+$ && "$VERSION_CODE" -lt 2100000000 ]] || die "bad VERSION_CODE $VERSION_CODE"
[[ -x "$READELF" ]] || die "llvm-readelf not found under \$ANDROID_HOME/ndk"
set -a; source "$KEYDIR/passwords.env"; set +a
[[ -n "${ANDROID_UPLOAD_STORE_PASS:-}" && -n "${ANDROID_APPSIGN_STORE_PASS:-}" ]] || die "passwords.env incomplete"

LOCK="${TMPDIR:-/tmp}/pocketdj-android-release.lock"
mkdir "$LOCK" 2>/dev/null || die "another Android release is running ($LOCK); remove it if stale"
WORK="$(mktemp -d)"
trap 'rm -rf "$LOCK" "$WORK"' EXIT

cd "$ANDROID_DIR"
GRADLE=(./gradlew -Pkotlin.compiler.execution.strategy=in-process
  "-PversionCode=$VERSION_CODE" "-PversionName=$VERSION_NAME" ${GRADLE_EXTRA_ARGS:-})
BASE="PocketDJ-$VERSION_NAME-$VERSION_CODE"
echo "==> PocketDJ Android $VERSION_NAME ($VERSION_CODE) -> $OUT_DIR"

# --- 1. AAB, upload key -------------------------------------------------------------------------
echo "==> bundleRelease (upload key)"
ANDROID_UPLOAD_STORE_FILE="$UPLOAD_P12" ANDROID_UPLOAD_KEY_ALIAS=upload \
  "${GRADLE[@]}" :app:bundleRelease
cp app/build/outputs/bundle/release/app-release.aab "$OUT_DIR/$BASE.aab"
cp app/build/outputs/mapping/release/mapping.txt "$OUT_DIR/mapping-$VERSION_CODE.txt" 2>/dev/null || true

# --- 2. Universal APK, app-signing key (matches Play's signature) -------------------------------
echo "==> assembleRelease (app-signing key)"
ANDROID_UPLOAD_STORE_FILE="$APPSIGN_P12" ANDROID_UPLOAD_KEY_ALIAS=pocketdj \
  ANDROID_UPLOAD_STORE_PASS="$ANDROID_APPSIGN_STORE_PASS" \
  "${GRADLE[@]}" :app:assembleRelease
cp app/build/outputs/apk/release/app-release.apk "$OUT_DIR/$BASE.apk"

# --- 3. Verify ----------------------------------------------------------------------------------
AAB="$OUT_DIR/$BASE.aab"; APK="$OUT_DIR/$BASE.apk"

echo "==> apksigner (APK must carry the app-signing cert)"
"$BT/apksigner" verify --verbose --print-certs "$APK" | grep -E "Verified using|certificate SHA-256" | tee "$WORK/apksig.txt"
grep -q "Verified using v2 scheme (APK Signature Scheme v2): true" "$WORK/apksig.txt" || die "APK not v2-signed"
grep -qi "SHA-256 digest: $APPSIGN_SHA256" "$WORK/apksig.txt" || die "APK cert != pinned app-signing cert"

echo "==> jarsigner (AAB must carry the upload cert)"
"$JAVA_HOME/bin/jarsigner" -verify "$AAB" | grep -q "jar verified" || die "AAB signature does not verify"
unzip -p "$AAB" 'META-INF/*.RSA' 'META-INF/*.EC' 'META-INF/*.DSA' 2>/dev/null > "$WORK/aab-sig.p7b" || true
AAB_CERT_SHA="$(openssl pkcs7 -inform DER -in "$WORK/aab-sig.p7b" -print_certs 2>/dev/null \
  | openssl x509 -outform DER 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"
echo "AAB signer certificate SHA-256: $AAB_CERT_SHA"
[[ "$AAB_CERT_SHA" == "$UPLOAD_SHA256" ]] || die "AAB cert != pinned upload cert"

echo "==> badging"
BADGING="$("$BT/aapt2" dump badging "$APK" | head -1)"
echo "$BADGING"
[[ "$BADGING" == *"name='com.levi.pocketdj'"* && "$BADGING" == *"versionCode='$VERSION_CODE'"* ]] \
  || die "APK package/versionCode mismatch"
"$BT/aapt2" dump permissions "$APK" > "$OUT_DIR/permissions.txt"

echo "==> ABIs + 16 KB LOAD alignment (every .so in AAB and APK)"
: > "$OUT_DIR/native-alignment.txt"
unzip -q -o "$AAB" 'base/lib/*' -d "$WORK/aab"
unzip -q -o "$APK" 'lib/*' -d "$WORK/apk"
fail=0
while IFS= read -r so; do
  rel="${so#"$WORK"/}"
  aligns="$("$READELF" -lW "$so" | awk '$1=="LOAD"{print $NF}' | sort -u | tr '\n' ' ')"
  bad=0
  for a in $aligns; do (( a >= 0x4000 )) || bad=1; done
  status=$([[ $bad == 0 ]] && echo OK || echo FAIL)
  printf '%-4s %-60s LOAD align: %s\n' "$status" "$rel" "$aligns" | tee -a "$OUT_DIR/native-alignment.txt"
  [[ $bad == 0 ]] || fail=1
done < <(find "$WORK/aab" "$WORK/apk" -name '*.so' | sort)
[[ $fail == 0 ]] || die "a native library is not 16 KB aligned"
abis="$(find "$WORK/apk/lib" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | tr '\n' ' ')"
echo "APK ABIs: $abis"
[[ "$abis" != *x86* ]] || die "x86 ABI in a release artifact (built with -PincludeX86?)"

echo "==> zipalign (16 KB for uncompressed .so)"
"$BT/zipalign" -c -P 16 4 "$APK" || die "APK zip alignment check failed"

# --- 4. Checksums -------------------------------------------------------------------------------
(cd "$OUT_DIR" && shasum -a 256 "$BASE.aab" "$BASE.apk" | tee SHA256SUMS)
ls -l "$AAB" "$APK"
echo "versionCode=$VERSION_CODE versionName=$VERSION_NAME"
echo "==> Done $VERSION_NAME ($VERSION_CODE)"
