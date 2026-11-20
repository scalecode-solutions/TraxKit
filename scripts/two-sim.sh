#!/usr/bin/env bash
# Two-simulator end-to-end check of live updates. Sim B signs in as the
# account that shares, and `simctl location` drives it along a route; sim A
# signs in as the viewer and sits on the Lab's conversation with B, whose
# header reads the kit's bridge. Screenshots of A are taken as B moves: if the
# coordinate and "Updated" lines change from shot to shot without A leaving the
# screen, bridge readers update live.
#
#   scripts/two-sim.sh <viewer-uuid> <sharer-uuid>
#
# The sharer must already share exact location with the viewer (and they must
# be friends) on the local stack. Env: SIM_A, SIM_B (simulator names, default
# TraxLab-A / TraxLab-B; neither exists by default now: create two or pass
# SIM_A / SIM_B), DD (build folder), SERVER (the mvTrax checkout),
# BASE (the API), OUT (shots folder, default /tmp/traxlab-two-sim), SHOTS
# (default 8), EVERY (seconds between shots, default 10), SPEED (m/s, default
# 25), ROUTE (space-separated lat,lng waypoints; default a loop of a few km).
set -euo pipefail
cd "$(dirname "$0")/.."
VIEWER=${1:?usage: scripts/two-sim.sh <viewer-uuid> <sharer-uuid>}
SHARER=${2:?usage: scripts/two-sim.sh <viewer-uuid> <sharer-uuid>}
SERVER=${SERVER:-../mvTrax}
BASE=${BASE:-http://localhost:6091}
DD=${DD:-/tmp/traxlab-dd}
OUT=${OUT:-/tmp/traxlab-two-sim}
SHOTS=${SHOTS:-8}
EVERY=${EVERY:-10}
SPEED=${SPEED:-25}
ROUTE=${ROUTE:-"37.3349,-122.0090 37.3318,-122.0312 37.3230,-122.0322 37.3236,-122.0110 37.3349,-122.0090"}
APP_ID=dev.scalecode.TraxLab

sim_id() { xcrun simctl list devices available | sed -nE "s/^ +$1 \(([0-9A-F-]{36})\).*/\1/p" | head -1; }
A=$(sim_id "${SIM_A:-TraxLab-A}"); B=$(sim_id "${SIM_B:-TraxLab-B}")
[ -n "$A" ] && [ -n "$B" ] || { echo "need two simulators: ${SIM_A:-TraxLab-A} and ${SIM_B:-TraxLab-B}"; exit 2; }
curl -fsS "$BASE/health" >/dev/null || { echo "mvTrax isn't up at $BASE"; exit 2; }
KEY=$(sed -n 's/^TOKEN_KEY=//p' "$SERVER/.env")
[ -n "$KEY" ] || { echo "no TOKEN_KEY in $SERVER/.env"; exit 2; }
mint() { (cd "$SERVER" && go run ./cmd/minttoken "$KEY" "$1"); }
TOKEN_A=$(mint "$VIEWER"); TOKEN_B=$(mint "$SHARER")

echo "building"
xcodebuild build -project Demo/TraxLab.xcodeproj -scheme TraxLab \
  -destination "platform=iOS Simulator,id=$A" -derivedDataPath "$DD" -quiet
APP=$(find "$DD/Build/Products" -maxdepth 2 -name TraxLab.app -path '*iphonesimulator*' | head -1)
[ -n "$APP" ] || { echo "no TraxLab.app in $DD"; exit 1; }

for S in "$A" "$B"; do
  xcrun simctl boot "$S" 2>/dev/null || true
  xcrun simctl bootstatus "$S" -b >/dev/null
  xcrun simctl install "$S" "$APP"
  xcrun simctl privacy "$S" grant location-always "$APP_ID" 2>/dev/null || xcrun simctl privacy "$S" grant location "$APP_ID"
  xcrun simctl privacy "$S" grant motion "$APP_ID" 2>/dev/null || true
  xcrun simctl terminate "$S" "$APP_ID" 2>/dev/null || true
done
open "$(xcode-select -p)/Applications/Simulator.app" 2>/dev/null || true   # to watch; screenshots don't need it

# B: the sharer, moving.
set -- $ROUTE
xcrun simctl location "$B" set "$1"
SIMCTL_CHILD_TRAX_DEV_TOKEN=$TOKEN_B SIMCTL_CHILD_TRAX_DEV_USER=$SHARER \
  xcrun simctl launch "$B" "$APP_ID" >/dev/null
sleep 5
xcrun simctl location "$B" start --speed="$SPEED" $ROUTE
trap 'xcrun simctl location "$B" clear >/dev/null 2>&1 || true' EXIT

# A: the viewer, parked on the conversation with B.
SIMCTL_CHILD_TRAX_DEV_TOKEN=$TOKEN_A SIMCTL_CHILD_TRAX_DEV_USER=$VIEWER \
SIMCTL_CHILD_LAB_FRIEND=$SHARER SIMCTL_CHILD_LAB_START=chats \
  xcrun simctl launch "$A" "$APP_ID" >/dev/null

# Delete only what this script writes, never $OUT itself: it's caller-supplied,
# and a typo must not wipe a tree.
mkdir -p "$OUT"; rm -f "$OUT"/viewer-*.png "$OUT/sharer-last.png"
for i in $(seq -w 1 "$SHOTS"); do
  sleep "$EVERY"
  xcrun simctl io "$A" screenshot --type=png "$OUT/viewer-$i.png" >/dev/null 2>&1
  echo "shot $OUT/viewer-$i.png"
done
xcrun simctl io "$B" screenshot --type=png "$OUT/sharer-last.png" >/dev/null 2>&1
echo "done: compare the coordinate and Updated lines across $OUT/viewer-*.png"
