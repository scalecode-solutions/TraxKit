# TraxKit

The location-sharing client as a self-contained iOS Swift package: the engine,
SwiftData persistence, revision-ordered sync over Connect, the device location
engine, and the screens a host embeds. Talks to **mvTrax**.

Friend-gated, **directed** sharing: you choose who sees your location and how
precisely; the social graph (synced into mvTrax) decides who you *can* share
with. The host owns sign-in, navigation and the engine's lifetime; the kit owns
everything behind the screens.

## Embedding

```swift
let config = TraxConfig(
    baseURL: URL(string: "https://trax.example.com")!,
    currentUserID: userID,
    tokenProvider: { await auth.accessToken() }   // a JWT the server accepts
)
let engine = TraxEngine(config: config, host: TraxLocationEngine())
```

One engine per signed-in person. The host drives its lifetime:

| Call | When |
|---|---|
| `engine.start()` / `stop()` | sign-in / the session ending. Sharing and place arrivals run app-wide while started. |
| `engine.acquire()` / `release()` | a screen showing others' locations appears / goes away. Held, the feed polls fast and refreshes at once on acquire. Counted. |
| `engine.setForeground(_:)` | from the app's scene phase. In the background the feed poll stops; sharing doesn't depend on it. |
| `engine.wipeStore()` | sign-out: deletes this person's local data. |

`TraxLocationEngine` is the kit's device engine (CoreLocation, motion,
battery, the place geofences). A host can bring its own by implementing
`TraxLocationHost`.

## Screens

All of them sit inside the host's `NavigationStack`; the host owns the
navigation bar.

| View | What it is |
|---|---|
| `TraxView(engine:appearance:focus:)` | `.everyone`: the map with people, weather and places. `.person(id)`: one person's map with a card (their status, my share to them, our places, their arrivals). |
| `TraxSettingsView(engine:extra:)` | my own settings: location access, my places, stop sharing with everyone, clear history, then the host's `extra` sections. |
| `TraxPairSettingsView(engine:otherID:)` | one person: my share to them (start, change, stop) and which of my places they see. |
| `TraxShareBadge(engine:otherID:)` | which way sharing goes with one person, for a list row or a header. |
| `TraxAppearance` | the person-facing wording, for a host to change. |

The screens are laid out for large text on a small phone: rows stack rather
than squeeze, and nothing sits under a floating tab bar.

## The engine API

Everything a host reads or does goes through `TraxEngine` (see
`TraxEngine+API.swift`). State is published as values, safe to read in a view
body: `people`, `places`, `outgoingShares`, `isSharing`, `relationship(with:)`,
`sharedPlaces(with:)`, `recentTransitions(with:)`. Verbs are async and throw:
`startSharing(with:precision:duration:)` (also how a live share is changed),
`stopSharing(with:)`, `stopAllSharing()`, `addPlace` / `updatePlace` /
`deletePlace`, `sharePlace` / `unsharePlace`, `clearHistory(before:)`,
`timeline(of:day:)`.

## Precision

A share's precision is how much it reveals, and it also sets how hard the
device tracks:

| Precision | Viewer sees | Tracking |
|---|---|---|
| exact | the live position | full rate, in the foreground and the background |
| place | which of the sharer's places they're at | ~100 m while the app is open; significant-change in the background |
| approx | an area of about a kilometre | ~1 km while the app is open; significant-change in the background |

The most precise live share sets the tier. A still phone keeps an exact share
current (a heartbeat every 90 s); only an exact share can show as
"Not updating".

## Never notifies

TraxKit posts no notifications and starts no Live Activities. Arrivals and
departures are ambient: they appear when someone looks. What iOS itself may
show because of location use is the OS's, not a notification from the kit:

- the location and motion permission prompts, only when the user acts (starts
  sharing, or taps "Allow location access");
- the background location indicator while an exact share runs in the
  background;
- iOS's periodic reminder that an app with "Always" access has been using
  location in the background.

## Demo

`Demo/TraxLab` hosts the kit the way a chat app does (a tab bar, a
conversation with links to the map and the location settings, settings in its
own tab). It's generated from `Demo/project.yml` with XcodeGen; see
`Demo/README.md` for the debug sign-in and the scripts.

## Test

```
xcodebuild test -scheme TraxKit -destination 'platform=iOS Simulator,name=<sim>'
scripts/ui-test.sh <account-uuid> [friend-uuid]     # TraxLab UI tests, local stack
scripts/two-sim.sh <viewer-uuid> <sharer-uuid>      # live updates across two simulators
```

`swift test` can't build the package: it's iOS-only (iOS 26). Swift 6 strict
concurrency throughout.
