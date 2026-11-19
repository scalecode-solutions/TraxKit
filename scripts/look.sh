#!/usr/bin/env bash
# Screenshots of Trax's screens in light, dark, and the largest accessibility
# text, for eyes (TraxLookUITests). Read-only against the LOCAL mvTrax.
#
#   scripts/look.sh <test-account-uuid> [friend-uuid]
#
# Env: SIM (default TraxLab-iPhone), DD, SERVER (the mvTrax checkout), BASE.
# Puts the simulator's scheme and text size back as it found them (a Lab sim
# may carry a deliberate setting, e.g. extra-extra-large text).
set -euo pipefail
cd "$(dirname "$0")/.."
USER_ID=${1:?usage: scripts/look.sh <test-account-uuid> [friend-uuid]}
FRIEND=${2:-}
SERVER=${SERVER:-../mvTrax}
SIM=${SIM:-TraxLab-iPhone}
SIM_ID=$(xcrun simctl list devices available | sed -nE "s/^ +$SIM \(([0-9A-F-]{36})\).*/\1/p" | head -1)
[ -n "$SIM_ID" ] || { echo "no simulator named $SIM"; exit 2; }
DD=${DD:-/tmp/traxlab-dd}
BASE=${BASE:-http://localhost:6091}
curl -fsS "$BASE/health" >/dev/null || { echo "mvTrax isn't up at $BASE"; exit 2; }
KEY=$(sed -n 's/^TOKEN_KEY=//p' "$SERVER/.env")
TOKEN=$(cd "$SERVER" && go run ./cmd/minttoken "$KEY" "$USER_ID")
OUT=/tmp/traxlab-look
rm -rf "$OUT"
WAS_SIZE=$(xcrun simctl ui "$SIM_ID" content_size)
WAS_LOOK=$(xcrun simctl ui "$SIM_ID" appearance)
restore() { xcrun simctl ui "$SIM_ID" appearance "$WAS_LOOK"; xcrun simctl ui "$SIM_ID" content_size "$WAS_SIZE"; }
trap restore EXIT
for mode in light dark xxxl; do
  case $mode in
    light) xcrun simctl ui "$SIM_ID" appearance light; xcrun simctl ui "$SIM_ID" content_size large ;;
    dark)  xcrun simctl ui "$SIM_ID" appearance dark;  xcrun simctl ui "$SIM_ID" content_size large ;;
    xxxl)  xcrun simctl ui "$SIM_ID" appearance light; xcrun simctl ui "$SIM_ID" content_size accessibility-extra-extra-extra-large ;;
  esac
  RESULT=/tmp/traxlab-look-$mode.xcresult
  rm -rf "$RESULT"
  (cd Demo && TEST_RUNNER_LOOK=1 TEST_RUNNER_LOOK_MODE=$mode TEST_RUNNER_TRAX_DEV_TOKEN=$TOKEN \
    TEST_RUNNER_TRAX_DEV_USER=$USER_ID TEST_RUNNER_LAB_FRIEND=$FRIEND \
    xcodebuild test -project TraxLab.xcodeproj -scheme TraxLab -destination "platform=iOS Simulator,id=$SIM_ID" \
      -derivedDataPath "$DD" -resultBundlePath "$RESULT" -only-testing:TraxLabUITests/TraxLookUITests/testLook 2>&1 \
      | grep -E "Test Case .*(passed|failed)|error:" || true)
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT/$mode" >/dev/null 2>&1 || true
done
find "$OUT" -name "*.png" | sort
