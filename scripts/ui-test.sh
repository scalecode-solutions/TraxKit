#!/usr/bin/env bash
# Runs TraxLab's UI tests against the LOCAL mvTrax as a test account, through
# the debug dev sign-in, on EACH simulator in SIMS, one after the other, and
# exports each check's screenshot to $SHOTS/<sim>. Read-only: the
# tests change nothing on the server.
#
#   scripts/ui-test.sh <test-account-uuid> [friend-uuid]
#
# With a friend who shares with the account, the conversation test runs too.
# Env: SIMS (simulator names, space-separated, so a name can't contain a
# space; the Lab sims' names don't; default "TraxLab-iPhone
# TraxLab-27": iOS 26 AND iOS 27, because layout differs between them and a
# 26-only gate let 0.7.2's card regress on 27, MVTRAX-39), SIM (one name,
# overrides SIMS), DD (build folder: give each person their own), ONLY (one
# test method), SERVER (the mvTrax checkout, for its .env TOKEN_KEY and
# cmd/minttoken), BASE (the API, default localhost:6091), SHOTS (where the
# screenshots and result bundles go, default /tmp/traxlab-shots: give each
# person their own, as with DD; two runs sharing it wipe each other's). A
# simulator this script boots is shut down again after its run.
set -euo pipefail
cd "$(dirname "$0")/.."
USER_ID=${1:?usage: scripts/ui-test.sh <test-account-uuid> [friend-uuid]}
FRIEND=${2:-}
SERVER=${SERVER:-../mvTrax}
SIMS=${SIM:-${SIMS:-TraxLab-iPhone TraxLab-27}}
SHOTS=${SHOTS:-/tmp/traxlab-shots}
DD=${DD:-/tmp/traxlab-dd}
ONLY=${ONLY:-}
[[ -n "$ONLY" && "$ONLY" != */* ]] && ONLY=TraxLabUITests/TraxLabUITests/$ONLY   # target/class/method
BASE=${BASE:-http://localhost:6091}
curl -fsS "$BASE/health" >/dev/null || { echo "mvTrax isn't up at $BASE"; exit 2; }
KEY=$(sed -n 's/^TOKEN_KEY=//p' "$SERVER/.env")
[ -n "$KEY" ] || { echo "no TOKEN_KEY in $SERVER/.env"; exit 2; }
TOKEN=$(cd "$SERVER" && go run ./cmd/minttoken "$KEY" "$USER_ID")
# Every simulator must exist before anything runs: a missing one is a failure,
# not a quietly smaller gate.
for SIM in $SIMS; do
  xcrun simctl list devices available | grep -qE "^ +$SIM \([0-9A-F-]{36}\)" || { echo "no simulator named $SIM"; exit 2; }
done
mkdir -p "$SHOTS"
STATUS=0
for SIM in $SIMS; do
  SIM_ID=$(xcrun simctl list devices available | sed -nE "s/^ +$SIM \(([0-9A-F-]{36})\).*/\1/p" | head -1)   # by id: xcodebuild sometimes misses a sim by name
  WAS_BOOTED=$(xcrun simctl list devices | grep -q "$SIM_ID) (Booted)" && echo yes || echo no)
  RESULT=$SHOTS/$SIM.xcresult
  # Delete only what this script writes for this simulator, never $SHOTS
  # itself: it's caller-supplied, and a typo must not wipe a tree.
  rm -rf "$RESULT" "$SHOTS/$SIM"
  echo "== $SIM"
  (cd Demo && TEST_RUNNER_TRAX_DEV_TOKEN=$TOKEN TEST_RUNNER_TRAX_DEV_USER=$USER_ID TEST_RUNNER_LAB_FRIEND=$FRIEND \
    xcodebuild test -project TraxLab.xcodeproj -scheme TraxLab \
      -destination "platform=iOS Simulator,id=$SIM_ID" -derivedDataPath "$DD" \
      -resultBundlePath "$RESULT" ${ONLY:+-only-testing:$ONLY} 2>&1 | grep -E "Test Case .*(passed|failed|skipped)|error:|\*\* TEST" || true)
  [ "$WAS_BOOTED" = yes ] || xcrun simctl shutdown "$SIM_ID" 2>/dev/null || true
  # Nothing ran (a misspelt ONLY, or a build that failed) is a failure, not a pass.
  SUMMARY=$(xcrun xcresulttool get test-results summary --path "$RESULT" 2>/dev/null || echo '{}')
  RAN=$(python3 -c "import json,sys;d=json.loads(sys.argv[1]);print(d.get('passedTests',0)+d.get('failedTests',0))" "$SUMMARY")
  FAILED=$(python3 -c "import json,sys;print(json.loads(sys.argv[1]).get('failedTests',0))" "$SUMMARY")
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "$SHOTS/$SIM" >/dev/null 2>&1 || true
  if [ "$RAN" = "0" ]; then echo "$SIM: no tests ran (check ONLY: $ONLY)"; STATUS=1
  elif [ "$FAILED" != "0" ]; then echo "$SIM: $FAILED failed"; STATUS=1
  else echo "$SIM: $RAN passed"; fi
done
for SIM in $SIMS; do ls -d "$SHOTS/$SIM" 2>/dev/null; done
exit $STATUS
