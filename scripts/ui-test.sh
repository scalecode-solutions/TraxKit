#!/usr/bin/env bash
# Runs TraxLab's UI tests against the LOCAL mvTrax as a test account, through
# the debug dev sign-in, and exports each check's screenshot to
# /tmp/traxlab-shots. Read-only: the tests change nothing on the server.
#
#   scripts/ui-test.sh <test-account-uuid> [friend-uuid]
#
# With a friend who shares with the account, the conversation test runs too.
# Env: SIM (simulator name, default TraxLab-iPhone), DD (build folder: give each
# person their own), ONLY (one test method), SERVER (the mvTrax checkout, for
# its .env TOKEN_KEY and cmd/minttoken), BASE (the API, default localhost:6091).
set -euo pipefail
cd "$(dirname "$0")/.."
USER_ID=${1:?usage: scripts/ui-test.sh <test-account-uuid> [friend-uuid]}
FRIEND=${2:-}
SERVER=${SERVER:-../mvTrax}
SIM=${SIM:-TraxLab-iPhone}
SIM_ID=$(xcrun simctl list devices available | sed -nE "s/^ +$SIM \(([0-9A-F-]{36})\).*/\1/p" | head -1)   # by id: xcodebuild sometimes misses a sim by name
[ -n "$SIM_ID" ] || { echo "no simulator named $SIM"; exit 2; }
DD=${DD:-/tmp/traxlab-dd}
ONLY=${ONLY:-}
[[ -n "$ONLY" && "$ONLY" != */* ]] && ONLY=TraxLabUITests/$ONLY
BASE=${BASE:-http://localhost:6091}
curl -fsS "$BASE/health" >/dev/null || { echo "mvTrax isn't up at $BASE"; exit 2; }
KEY=$(sed -n 's/^TOKEN_KEY=//p' "$SERVER/.env")
[ -n "$KEY" ] || { echo "no TOKEN_KEY in $SERVER/.env"; exit 2; }
TOKEN=$(cd "$SERVER" && go run ./cmd/minttoken "$KEY" "$USER_ID")
RESULT=/tmp/traxlab-ui.xcresult
rm -rf "$RESULT" /tmp/traxlab-shots
cd Demo
TEST_RUNNER_TRAX_DEV_TOKEN=$TOKEN TEST_RUNNER_TRAX_DEV_USER=$USER_ID TEST_RUNNER_LAB_FRIEND=$FRIEND \
  xcodebuild test -project TraxLab.xcodeproj -scheme TraxLab \
    -destination "platform=iOS Simulator,id=$SIM_ID" -derivedDataPath "$DD" \
    -resultBundlePath "$RESULT" ${ONLY:+-only-testing:$ONLY} 2>&1 | grep -E "Test Case .*(passed|failed|skipped)|error:|\*\* TEST" || true
# Nothing ran (a misspelt ONLY) is a failure, not a pass.
SUMMARY=$(xcrun xcresulttool get test-results summary --path "$RESULT" 2>/dev/null || echo '{}')
RAN=$(python3 -c "import json,sys;d=json.loads(sys.argv[1]);print(d.get('passedTests',0)+d.get('failedTests',0))" "$SUMMARY")
FAILED=$(python3 -c "import json,sys;print(json.loads(sys.argv[1]).get('failedTests',0))" "$SUMMARY")
[ "$RAN" != "0" ] || { echo "no tests ran: check ONLY ($ONLY)"; exit 1; }
xcrun xcresulttool export attachments --path "$RESULT" --output-path /tmp/traxlab-shots >/dev/null 2>&1 || true
ls /tmp/traxlab-shots 2>/dev/null | head -20
[ "$FAILED" = "0" ]
