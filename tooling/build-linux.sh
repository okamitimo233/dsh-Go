#!/usr/bin/env bash
# Builds the Linux x86_64 desktop app.
#
# Requirements:
#   - Flutter 3.47.7 on PATH
#   - clang, cmake, ninja, pkg-config and GTK 3 development headers
#   - absolute first-run backend dependency: Node.js >= 20 and npm on PATH
#
# The backend is installed at first run from the official npm registry into the
# user's application support directory and runs directly as a host process; no
# Docker, PRoot or other container is used.
#
#   tooling/build-linux.sh              # release
#   tooling/build-linux.sh --debug      # debug
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP="$ROOT/app"
mode=release
case "${1:-}" in
  --debug) mode=debug ;;
  --release | '') ;;
  -h | --help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "build-linux: unknown option: $1" >&2; exit 2 ;;
esac

command -v flutter >/dev/null || { echo "build-linux: flutter is not on PATH" >&2; exit 1; }

cd "$APP"
flutter pub get --enforce-lockfile
flutter build linux "--$mode"
echo "built: $APP/build/linux/x64/$mode/bundle/dsh_app"
