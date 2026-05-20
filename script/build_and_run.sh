#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="XcodeCacheCleaner"
BUNDLE_ID="cn.yicheng2031.XcodeCacheCleaner"
PROJECT="XcodeCacheCleaner.xcodeproj"
SCHEME="XcodeCacheCleaner"
CONFIGURATION="Debug"
ARCH="$(uname -m)"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cd "$ROOT_DIR"

build_app() {
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS,arch=$ARCH" \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet \
    build
}

stop_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    parent_pid="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')"
    parent_cmd="$(ps -p "$parent_pid" -o comm= 2>/dev/null || true)"
    if [[ "$parent_cmd" == *debugserver* ]]; then
      kill "$parent_pid" >/dev/null 2>&1 || true
    fi
    kill "$pid" >/dev/null 2>&1 || true
  done < <(pgrep -f "/${APP_NAME}[.]app/Contents/MacOS/${APP_NAME}" || true)

  sleep 0.3

  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    parent_pid="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')"
    parent_cmd="$(ps -p "$parent_pid" -o comm= 2>/dev/null || true)"
    if [[ "$parent_cmd" == *debugserver* ]]; then
      kill -9 "$parent_pid" >/dev/null 2>&1 || true
    fi
    kill -9 "$pid" >/dev/null 2>&1 || true
  done < <(pgrep -f "/${APP_NAME}[.]app/Contents/MacOS/${APP_NAME}" || true)
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

stop_app
build_app

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -f "$APP_BINARY" >/dev/null
    ;;
  *)
    usage
    exit 2
    ;;
esac
