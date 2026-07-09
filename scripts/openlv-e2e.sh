#!/usr/bin/env bash
# Cross-stack openlv E2E: boots the desktop-host harness from the
# freedom-browser repo (local MQTT broker + Chromium host page), then
# runs OpenLVHarnessTests in the iOS simulator against it. The simulator
# shares the Mac's loopback, so everything meets at 127.0.0.1.
#
# Overrides: FREEDOM_BROWSER_DIR (sibling checkout by default),
# OPENLV_HARNESS_PORT (8798), OPENLV_SIM_NAME (iPhone 17).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BROWSER_REPO="${FREEDOM_BROWSER_DIR:-$(cd "$SCRIPT_DIR/../../../freedom-browser" && pwd)}"
PORT="${OPENLV_HARNESS_PORT:-8798}"
SIM_NAME="${OPENLV_SIM_NAME:-iPhone 17}"

if [[ ! -f "$BROWSER_REPO/scripts/openlv-ios-harness.js" ]]; then
  echo "freedom-browser checkout with the openlv harness not found at $BROWSER_REPO" >&2
  echo "(set FREEDOM_BROWSER_DIR, and make sure that checkout is on feature/openlv)" >&2
  exit 1
fi

OPENLV_HARNESS_PORT="$PORT" node "$BROWSER_REPO/scripts/openlv-ios-harness.js" &
HARNESS_PID=$!
trap 'kill "$HARNESS_PID" 2>/dev/null || true' EXIT

echo "waiting for the harness session URI on port $PORT ..."
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$PORT/uri" 2>/dev/null | grep -q 'openlv://'; then
    break
  fi
  sleep 1
done
curl -fsS "http://127.0.0.1:$PORT/uri" | grep -q 'openlv://' || {
  echo "harness never produced a session URI" >&2
  exit 1
}

cd "$SCRIPT_DIR/../Freedom"
TEST_RUNNER_OPENLV_HARNESS_URL="http://127.0.0.1:$PORT" xcodebuild test \
  -project Freedom.xcodeproj \
  -scheme Freedom \
  -destination "platform=iOS Simulator,name=$SIM_NAME" \
  -only-testing:FreedomTests/OpenLVHarnessTests
