#!/usr/bin/env bash
# Capture a profile frame-probe run and check its frame budget.
#
# Usage:
#   tooling/benchmark-linux.sh [--seconds 20] [--no-build] [--no-check]
#       [--budget-ms 16.667] [--log PATH]
#       [--min-frames N] [--max-p95-ms MS] [--max-p99-ms MS]
#       [--max-jank-ratio R] [--min-fps FPS] [--skip-windows N]
#       [--max-windows N] [--require-active]
#
# Start it, then interact with the DSH window for the whole capture period:
# scroll a conversation, open/close the drawer, type in the composer. The
# profile process is stopped when the timer ends; its probe log is validated by
# tooling/frame_probe_check.py.
#
# For a scaling pass, set the GTK environment before this script, e.g.
#   GDK_SCALE=1.5 tooling/benchmark-linux.sh --require-active --min-fps 55
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP="$ROOT/app"
BUNDLE="$APP/build/linux/x64/profile/bundle/dsh_app"
LOG="$APP/build/linux/frame-probe.log"
SECONDS_TO_RUN=20
DO_BUILD=1
DO_CHECK=1
BUDGET_MS=16.667
SKIP_WINDOWS=1
MAX_WINDOWS=0
CHECK_ARGS=()

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while (($#)); do
  case "$1" in
    --seconds)
      SECONDS_TO_RUN=${2:?--seconds needs a value}
      shift 2
      ;;
    --log)
      LOG=${2:?--log needs a path}
      shift 2
      ;;
    --budget-ms)
      BUDGET_MS=${2:?--budget-ms needs a value}
      shift 2
      ;;
    --no-build)
      DO_BUILD=0
      shift
      ;;
    --no-check)
      DO_CHECK=0
      shift
      ;;
    --min-frames | --max-p95-ms | --max-p99-ms | --max-jank-ratio | --min-fps)
      CHECK_ARGS+=("$1" "${2:?$1 needs a value}")
      shift 2
      ;;
    --skip-windows)
      SKIP_WINDOWS=${2:?--skip-windows needs a value}
      shift 2
      ;;
    --max-windows)
      MAX_WINDOWS=${2:?--max-windows needs a value}
      shift 2
      ;;
    --require-active)
      CHECK_ARGS+=("$1")
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "benchmark-linux: unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if ! [[ $SECONDS_TO_RUN =~ ^[1-9][0-9]*$ ]]; then
  echo "benchmark-linux: --seconds must be a positive integer" >&2
  exit 2
fi
if ! [[ $BUDGET_MS =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "benchmark-linux: --budget-ms must be a positive number" >&2
  exit 2
fi
BUDGET_US=$(awk -v ms="$BUDGET_MS" 'BEGIN { printf "%.0f", ms * 1000 }')

command -v flutter >/dev/null || { echo "benchmark-linux: flutter is not on PATH" >&2; exit 1; }
command -v python3 >/dev/null || { echo "benchmark-linux: python3 is not on PATH" >&2; exit 1; }

if ((DO_BUILD)); then
  (
    cd "$APP"
    flutter pub get --enforce-lockfile
    flutter build linux --profile \
      --dart-define=DSH_FRAME_PROBE=true \
      --dart-define="DSH_FRAME_PROBE_BUDGET_US=$BUDGET_US"
  )
fi
[[ -x $BUNDLE ]] || { echo "benchmark-linux: missing $BUNDLE (run without --no-build)" >&2; exit 1; }

mkdir -p "$(dirname "$LOG")"
: >"$LOG"
echo "Recording for ${SECONDS_TO_RUN}s. Interact with the DSH window now."
echo "Log: $LOG"

app_pid=
cleanup() {
  if [[ -n ${app_pid:-} ]]; then
    kill -TERM "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
    app_pid=
  fi
}
trap cleanup EXIT INT TERM

if command -v stdbuf >/dev/null; then
  stdbuf -oL -eL "$BUNDLE" >"$LOG" 2>&1 &
else
  "$BUNDLE" >"$LOG" 2>&1 &
fi
app_pid=$!

# Let the app's first frames and the probe's 5-second reporter run while the
# person uses the window. If the app exits early, stop waiting and validate
# whatever was captured.
for ((i = 0; i < SECONDS_TO_RUN; i++)); do
  sleep 1
  kill -0 "$app_pid" 2>/dev/null || break
done
cleanup
trap - EXIT INT TERM

echo "Frame probe log: $LOG"
if ((DO_CHECK)); then
  python3 "$ROOT/tooling/frame_probe_check.py" "$LOG" --skip-windows "$SKIP_WINDOWS" --max-windows "$MAX_WINDOWS" "${CHECK_ARGS[@]}"
else
  echo "Skipped validation (--no-check)."
fi
