#!/usr/bin/env bash
# Builds an installable APK for MailChat from assets/config/env (or a root .env).
#
#   ./tool/build_apk.sh                 # debug build, signed with the debug key
#   ./tool/build_apk.sh --mode release  # needs a keystore; see --signing-help
#   ./tool/build_apk.sh --fat           # one APK for every ABI, bigger
#
# Mirrors tool/build_apk.ps1; see docs/building.md.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

mode="debug"
fat=0
abi=""
skip_links=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) mode="${2:?--mode needs a value}"; shift 2 ;;
    --fat) fat=1; shift ;;
    --abi) abi="${2:?--abi needs a value}"; shift 2 ;;
    --skip-deep-links) skip_links=1; shift ;;
    --signing-help) sed -n '/Release signing is not configured/,/refuses to install it/p' "$0" 2>/dev/null || true
      cat <<'HELP'
Release signing is not configured in this repository.
1. keytool -genkey -v -keystore ~/mailchat-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
2. Create android/key.properties (gitignored): storeFile, storePassword, keyAlias, keyPassword
3. Add a signingConfigs block to android/app/build.gradle, then: ./tool/build_apk.sh --mode release
Without step 3 the release APK is unsigned and Android refuses to install it.
HELP
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# The tool scripts import package:mailchat, which needs a resolved package graph.
if [[ ! -f .dart_tool/package_config.json ]]; then
  echo "Resolving dependencies (first run)"
  flutter pub get
fi

env_file="assets/config/env"
if [[ -f .env ]]; then
  cp .env "$env_file"
  echo "Synced .env -> $env_file"
fi

if [[ ! -f "$env_file" ]]; then
  echo "error: no configuration. Copy assets/config/env.example to assets/config/env and fill it in (docs/running.md section 1)." >&2
  exit 1
fi

# Validation lives in one place — tool/check_config.dart uses the same parser
# the app does (lib/core/config/env_file.dart), so this cannot disagree with
# what the APK will actually read at startup.
dart run tool/check_config.dart

if [[ $skip_links -eq 0 ]]; then
  dart run tool/enable_deep_links.dart
fi

args=(build apk "--$mode")
if [[ -n "$abi" ]]; then
  args+=("--target-platform=android-$abi")
elif [[ $fat -eq 0 ]]; then
  args+=(--split-per-abi)
fi

echo "Building: flutter ${args[*]}"
flutter "${args[@]}"

out="build/app/outputs/flutter-apk"
mapfile -t apks < <(find "$out" -name '*.apk' ! -name '*unsigned*' -newermt '-30 minutes' | sort)
if [[ ${#apks[@]} -eq 0 ]]; then
  echo "error: build succeeded but no APK found in $out" >&2
  exit 1
fi

echo
echo "APK(s):"
for apk in "${apks[@]}"; do
  printf '  %s  (%s MB)\n' "$apk" "$(du -m "$apk" | cut -f1)"
done
echo
echo "Install on a connected device:"
echo "  adb install -r \"${apks[0]}\""
if [[ "$mode" == release ]]; then
  echo
  echo "Release builds are unsigned unless android/key.properties is configured; Android refuses to install those. See --signing-help."
fi
