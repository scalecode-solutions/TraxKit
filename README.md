# TraxKit

The location-sharing client as a self-contained iOS SPM — wire DTOs, REST
transport, SwiftData persistence, pull-sync, and the embedded map/share UI. Talks
to **mvTrax**. A host (TraxLab / Clingy) adds a thin wrapper. Mirrors PulseKit.

Friend-gated, **directed** sharing over HTTP (poll, no socket): you choose who
sees your location; the social graph (synced into mvTrax) gates who you *can*
share with and labels them. See `mvTrax/docs/DESIGN.md` for the full positioning.

## Shape

| Layer | Type |
|---|---|
| `TraxConfig` | base URL + currentUserID + async token provider |
| `TraxTransport` | protocol + `HTTPTraxTransport` (Bearer, typed error envelope) |
| `TraxStore` | `@MainActor` SwiftData (`ShareEntity`, `ContactEntity`, cursor) |
| `TraxSync` | `@MainActor @Observable` — delta-pull feed + share/track mutations |
| `TraxLocationView` | embedded MapKit screen + share sheet |

## Wiring a consumer

```swift
let config = TraxConfig(
    baseURL: URL(string: "https://trax.mvchat.app")!,
    currentUserID: myUserID,
    tokenProvider: { await auth.accessToken() }   // an mvServer JWT
)
TraxLocationView(config: config, store: TraxStore())
```

## Demo

`Demo/TraxLab` — a literal copy of PulseLab, swapped to TraxKit. Logs in against
mvServer via the `MvAuth` package (Production / **Local** picker), then drives
mvTrax. Develop against **Local** (`http://localhost:6091` + `ws://localhost:6070`);
production is present but never selected during development.

## Test

```
swift test                                   # DTO/wire decoding (no server)
```

Swift 6 strict concurrency from line one. iOS-only (iOS 26).
