#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flutter_bin="${USERNET_FLUTTER_BIN:-flutter}"
sdk_dir="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
build_tools="${USERNET_ANDROID_BUILD_TOOLS:-$sdk_dir/build-tools/36.0.0}"
aapt_bin="${USERNET_AAPT_BIN:-$build_tools/aapt}"
apksigner_bin="${USERNET_APKSIGNER_BIN:-$build_tools/apksigner}"

if [[ ! -x "$aapt_bin" || ! -x "$apksigner_bin" ]]; then
  echo 'Android build-tools (aapt and apksigner) are required.' >&2
  exit 1
fi

unset USERNET_KEYSTORE_FILE USERNET_SIGNING_PASSWORD USERNET_SIGNING_ALIAS
unset USERNET_SIGNING_KEY_PASSWORD USERNET_KEYSTORE_TYPE
export USERNET_SIGNING_DEFERRED=true

cd "$repo_dir"
bash "$repo_dir/scripts/build-usernet-relay.sh"
"$flutter_bin" build apk --release --target-platform android-arm64 \
  --dart-define=USERNET_ADMIN_BUILD=false \
  --dart-define=APP_ENV=stable

apk="$repo_dir/build/app/outputs/flutter-apk/app-release.apk"
if [[ ! -s "$apk" ]]; then
  echo 'Flutter did not produce the stable APK.' >&2
  exit 1
fi

metadata="$("$aapt_bin" dump badging "$apk")"
package_name="$(sed -n "s/^package: name='\\([^']*\\)'.*/\\1/p" <<< "$metadata" | head -1)"
version_name="$(sed -n "s/^package: .*versionName='\\([^']*\\)'.*/\\1/p" <<< "$metadata" | head -1)"
version_code="$(sed -n "s/^package: .*versionCode='\\([^']*\\)'.*/\\1/p" <<< "$metadata" | head -1)"
version_line="$(sed -n 's/^version: //p' "$repo_dir/pubspec.yaml" | head -1)"
expected_version="${version_line%%+*}"
expected_build="${version_line##*+}"
if [[ "$package_name" != com.userlay.usernet ||
      "$version_name" != "$expected_version" ||
      "$version_code" != "$expected_build" ]]; then
  echo 'Unsigned APK metadata does not match the stable release.' >&2
  exit 1
fi

if "$apksigner_bin" verify --verbose "$apk" >/dev/null 2>&1; then
  echo 'Expected an unsigned stable APK for isolated signing.' >&2
  exit 1
fi

output_dir="$repo_dir/build/usernet-releases"
mkdir -p "$output_dir"
output="$output_dir/usernet-unsigned-stable-${expected_version//+/-}-${expected_build}.apk"
cp "$apk" "$output"
sha256sum "$output"
echo "Unsigned stable APK: $output"
