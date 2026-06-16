# TraxLab — TraxKit harness app

A throwaway SwiftUI app that loads the local TraxKit package and renders the
feed, so the card design can be exercised against real iOS coupling (Liquid
Glass, SwiftData, the simulator) — the same pattern as `BallSort/Demo`.

Runs **fully offline** on curated sample data (`SampleData.swift`): an in-memory
`SampleTransport` (an actor, so posts/reactions persist across pull-to-refresh)
plus a `SampleRoster` author resolver. Covers every card state — emoji-only,
short, long (collapse), reactions, replies, private, ephemeral.

## Run

```bash
# build for the ClingyLab simulator
xcodebuild -project Demo/TraxLab.xcodeproj -scheme TraxLab \
  -destination 'platform=iOS Simulator,name=ClingyLab-iPhone16' \
  CODE_SIGNING_ALLOWED=NO build

# or just open it and hit Run
open Demo/TraxLab.xcodeproj
```

`xcrun simctl launch <sim> dev.scalecode.TraxLab` to relaunch;
`xcrun simctl io <sim> screenshot out.png` to capture.

## Pointing at a live mvPulse

Swap `SampleData.transport` for `HTTPPulseTransport(baseURL:tokenProvider:)`
against `http://localhost:6090` (the simulator reaches the host's localhost
directly), with `tokenProvider` minting an HS256 token over the shared
`TOKEN_KEY`. Seed `audience_edges` via `PUT /v0/dev/audience` first.

## Wiring

The whole integration is `ContentView.swift` — `PulseFeedView(config:…, embedded:
true)` in a `NavigationStack` with a `.tint(TARDIS blue)`. That's the den-style
contract: TraxKit owns everything behind the view; the host injects config +
tint and wraps it in nav chrome.
