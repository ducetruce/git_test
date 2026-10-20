#!/bin/bash
# Launches the built app in an iOS Simulator and checks it survives, in the
# situations a real install meets: a saved robot (the sleepy fake robot on
# 127.0.0.1) and a malformed saved address. Prints the app's connection log
# and any crash report.
#
# Usage: tools/sim_smoke.sh <path to NarwalLocal.app>
set -uo pipefail

APP="$1"
BUNDLE=local.narwal.NarwalLocal
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
print(next(d["udid"] for runtime, ds in devices.items() if "iOS" in runtime for d in ds if d["name"].startswith("iPhone")))')
echo "Simulator: $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"

failed=0
run_case() {
  local name="$1" host="$2" expect="$3"
  echo "::group::$name (robotHost=$host)"
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  xcrun simctl spawn "$UDID" defaults write "$BUNDLE" robotHost "$host"
  xcrun simctl spawn "$UDID" defaults write "$BUNDLE" launchInProgress -bool NO
  local started; started=$(date "+%Y-%m-%d %H:%M:%S")
  xcrun simctl launch "$UDID" "$BUNDLE"
  sleep 25
  if xcrun simctl spawn "$UDID" launchctl list | grep -q "$BUNDLE"; then
    echo "alive after 25 s"
  else
    echo "::error::$name: app is not running (crashed)"
    failed=1
  fi
  local log; log=$(xcrun simctl spawn "$UDID" log show --style compact --start "$started" \
    --predicate 'subsystem == "local.narwal"' 2>/dev/null)
  echo "$log"
  if [ -n "$expect" ] && ! grep -q "$expect" <<<"$log"; then
    echo "::error::$name: expected log line '$expect' not found"
    failed=1
  fi
  echo "::endgroup::"
}

run_case "saved robot, sleeping" "127.0.0.1" "Identified robot DrzDKQ0MU8 / fakerobot01"
run_case "malformed saved address" "127.0.0.1%en0" "Identified robot"
run_case "unreachable address" "bad host name" ""

for f in ~/Library/Logs/DiagnosticReports/NarwalLocal*; do
  [ -e "$f" ] || continue
  echo "::group::Crash report $f"
  head -c 20000 "$f"
  echo "::endgroup::"
done
exit $failed
