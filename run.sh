#!/usr/bin/env bash
# Runs MailChat on a device, with no --dart-define flags.
#
# Configuration is read from `assets/config/env` at runtime (see
# assets/config/README.md), so `flutter run` alone is enough. This script only
# saves the copy step: if you keep a root `.env` out of habit, it is synced into
# the bundled asset first.
#
#   ./run.sh                 # first available device
#   ./run.sh -d emulator-5554
#   ./run.sh --release
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_file="$root/.env"
target="$root/assets/config/env"

if [[ -f "$source_file" ]]; then
  cp "$source_file" "$target"
  echo "Synced .env -> assets/config/env"
elif [[ ! -f "$target" ]]; then
  echo "warning: no configuration found. Copy assets/config/env.example to assets/config/env and fill it in." >&2
fi

cd "$root"
exec flutter run "$@"
