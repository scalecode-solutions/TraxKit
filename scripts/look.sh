#!/usr/bin/env bash
# Screenshots of Trax's screens in light, dark, and the largest accessibility
# text, for eyes (TraxLookUITests), on EACH simulator in SIMS. Read-only
# against the LOCAL mvTrax.
#
#   scripts/look.sh <test-account-uuid> [friend-uuid]
#
# Env: SIMS (simulator names, space-separated; default "TraxLab-iPhone
# TraxLab-27": iOS 26 and iOS 27 lay out differently, MVTRAX-39), SIM (one
# name, overrides SIMS), DD, SERVER (the mvTrax checkout), BASE, OUT (default
# /tmp/traxlab-look: give each person their own). Shots land in
# $OUT/<sim>/<mode>.
# Puts each simulator's scheme and text size back as it found them (a Lab sim
# may carry a deliberate setting, e.g. extra-extra-large text), and shuts down
# a simulator this script booted.
set -euo pipefail
cd "$(dirname "$0")/.."
USER_ID=${1:?usage: scripts/look.sh <test-account-uuid> [friend-uuid]}
FRIEND=${2:-}
SERVER=${SERVER:-../mvTrax}
SIMS=${SIM:-${SIMS:-TraxLab-iPhone TraxLab-27}}
DD=${DD:-/tmp/traxlab-dd}
BASE=${BASE:-http://localhost:6091}
curl -fsS "$BASE/health" >/dev/null || { echo "mvTrax isn't up at $BASE"; exit 2; }
for SIM in $SIMS; do
  xcrun simctl list devices available | grep -qE "^ +$SIM \([0-9A-F-]{36}\)" || { echo "no simulator named $SIM"; exit 2; }
done
KEY=$(sed -n 's/^TOKEN_KEY=//p' "$SERVER/.env")
TOKEN=$(cd "$SERVER" && go run ./cmd/minttoken "$KEY" "$USER_ID")
OUT=${OUT:-/tmp/traxlab-look}
rm -rf "$OUT"; mkdir -p "$OUT"

SIM_ID= WAS_SIZE= WAS_LOOK= WAS_BOOTED=
restore() {
  [ -n "$SIM_ID" ] || return 0
  # appearance/content_size need a booted device; boot isn't kept if it wasn't ours.
  xcrun simctl ui "$SIM_ID" appearance "$WAS_LOOK" 2>/dev/null || true
  xcrun simctl ui "$SIM_ID" content_size "$WAS_SIZE" 2>/dev/null || true
  [ "$WAS_BOOTED" = yes ] || xcrun simctl shutdown "$SIM_ID" 2>/dev/null || true
  SIM_ID=
}
trap restore EXIT

for SIM in $SIMS; do
  SIM_ID=$(xcrun simctl list devices available | sed -nE "s/^ +$SIM \(([0-9A-F-]{36})\).*/\1/p" | head -1)
  WAS_BOOTED=$(xcrun simctl list devices | grep -q "$SIM_ID) (Booted)" && echo yes || echo no)
  xcrun simctl bootstatus "$SIM_ID" -b >/dev/null   # `simctl ui` needs it booted
  WAS_SIZE=$(xcrun simctl ui "$SIM_ID" content_size)
  WAS_LOOK=$(xcrun simctl ui "$SIM_ID" appearance)
  echo "== $SIM"
  for mode in light dark xxxl; do
    case $mode in
      light) xcrun simctl ui "$SIM_ID" appearance light; xcrun simctl ui "$SIM_ID" content_size large ;;
      dark)  xcrun simctl ui "$SIM_ID" appearance dark;  xcrun simctl ui "$SIM_ID" content_size large ;;
      xxxl)  xcrun simctl ui "$SIM_ID" appearance light; xcrun simctl ui "$SIM_ID" content_size accessibility-extra-extra-extra-large ;;
    esac
    RESULT=$OUT/$SIM-$mode.xcresult
    rm -rf "$RESULT"
    (cd Demo && TEST_RUNNER_LOOK=1 TEST_RUNNER_LOOK_MODE=$mode TEST_RUNNER_TRAX_DEV_TOKEN=$TOKEN \
      TEST_RUNNER_TRAX_DEV_USER=$USER_ID TEST_RUNNER_LAB_FRIEND=$FRIEND \
      xcodebuild test -project TraxLab.xcodeproj -scheme TraxLab -destination "platform=iOS Simulator,id=$SIM_ID" \
        -derivedDataPath "$DD" -resultBundlePath "$RESULT" -only-testing:TraxLabUITests/TraxLookUITests/testLook 2>&1 \
        | grep -E "Test Case .*(passed|failed)|error:" || true)
    xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT/$SIM/$mode" >/dev/null 2>&1 || true
  done
  restore
done
find "$OUT" -name "*.png" | sort
