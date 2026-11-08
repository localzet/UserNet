#!/usr/bin/env bash
set -euo pipefail

release_channel="${1:-stable}"
if [[ "$release_channel" != stable && "$release_channel" != admin ]]; then
  echo 'Usage: build-usernet-release.sh [stable|admin]' >&2
  exit 2
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flutter_bin="${USERNET_FLUTTER_BIN:-flutter}"
signing_dir="${USERNET_SIGNING_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/usernet}"
password_file="$signing_dir/signing.password"
keystore_file="$signing_dir/usernet-release.p12"

if [[ ! -s "$password_file" || ! -s "$keystore_file" ]]; then
  echo 'Release signing key or password is missing.' >&2
  exit 1
fi

export USERNET_KEYSTORE_FILE="$keystore_file"
export USERNET_SIGNING_PASSWORD="$(<"$password_file")"
export USERNET_SIGNING_ALIAS=usernet
export USERNET_KEYSTORE_TYPE=PKCS12

if [[ "$release_channel" == admin ]]; then
  if [[ -z "${USERNET_ADMIN_API_URL:-}" ||
        ! "$USERNET_ADMIN_API_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[^?#]*)?$ ]]; then
    echo 'Set USERNET_ADMIN_API_URL to the private HTTPS API base before building Control.' >&2
    exit 2
  fi
  dart_defines=(
    '--dart-define=USERNET_ADMIN_BUILD=true'
    '--dart-define=APP_ENV=stable'
    "--dart-define=USERNET_ADMIN_API_URL=$USERNET_ADMIN_API_URL"
  )
else
  unset USERNET_ADMIN_API_URL || true
  dart_defines=('--dart-define=USERNET_ADMIN_BUILD=false' '--dart-define=APP_ENV=stable')
fi

cd "$repo_dir"
"$repo_dir/scripts/build-usernet-relay.sh"
"$flutter_bin" build apk --release --target-platform android-arm64 "${dart_defines[@]}"

version="$(sed -n 's/^version: //p' pubspec.yaml | head -1)"
output_dir="$repo_dir/build/usernet-releases"
mkdir -p "$output_dir"
output="$output_dir/usernet-$release_channel-${version//+/-}.apk"
cp "$repo_dir/build/app/outputs/flutter-apk/app-release.apk" "$output"

apksigner_bin="${USERNET_APKSIGNER_BIN:-$HOME/Android/Sdk/build-tools/36.0.0/apksigner}"
"$apksigner_bin" verify --verbose "$output" >/dev/null

if [[ "$release_channel" == stable ]]; then
  aapt_bin="${USERNET_AAPT_BIN:-$HOME/Android/Sdk/build-tools/36.0.0/aapt}"
  package_name="$("$aapt_bin" dump badging "$output" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1)"
  if [[ "$package_name" != com.userlay.usernet ]]; then
    echo 'Refusing to accept an APK with the wrong application ID.' >&2
    exit 1
  fi
  actual_version="$("$aapt_bin" dump badging "$output" | sed -n "s/^package: .*versionName='\([^']*\)'.*/\1/p" | head -1)"
  actual_build="$("$aapt_bin" dump badging "$output" | sed -n "s/^package: .*versionCode='\([^']*\)'.*/\1/p" | head -1)"
  if [[ "$actual_version" != "${version%%+*}" || "$actual_build" != "${version##*+}" ]]; then
    echo 'Refusing to accept an APK whose version does not match pubspec.yaml.' >&2
    exit 1
  fi
  if unzip -p "$output" lib/arm64-v8a/libapp.so | strings | \
      grep -Eq 'eyJhbGciOi|-----BEGIN PRIVATE KEY-----|ADMIN_DEVICE_TOKEN_SHA256|/admin/(auth|network|users|purchases)'; then
    echo 'Refusing to accept a public APK containing credential or Control markers.' >&2
    exit 1
  fi
fi

sha256sum "$output"
echo "Release APK: $output"
