# TraxKit Rebuild — Target Architecture

Status: design locked, pre-implementation. This is the canonical record of the
boundary decisions made before re-laying TraxKit's foundations.

## Framing

TraxKit is a dedicated location **data rail**, not a passenger on the chat wire.
The original "Tangle" feature stuffed location into Clingy's chat WebSocket; TraxKit
is its own end-to-end pipe (device cache → its own Connect wire → mvTrax → back).
The host plugs hardware into one end and reads chat-renderable state off the other.

## The boundary (locked)

- **Host (Clingy in prod / TraxLab in dev) = the location ENGINE.** Owns *all*
  CoreLocation hardware: the single `CLLocationManager`, the rolling-20 geofence,
  motion + battery enrichment, the auth prompt, background + cold-launch, and the
  active/passive/significant *tier mechanism*. **Stores no Trax data.**
- **TraxKit = DATA + TRANSPORT + UI.** The store, sync, bridge, the Connect wire,
  the share/place/transition domain, and the embeddable UI. **Owns ALL persistence —
  SwiftData (local) + mvTrax (server).** Touches zero device APIs.

Rule of thumb: anything that touches the location *hardware* → engine → host.
Anything that's *data, network, or screen* → kit.

## Persistence rule

The host persists nothing. TraxKit is the single owner of Trax data — SwiftData
locally, mvTrax remotely; those are the *only two places* Trax data ever lives.

- Guarantees the decoupling by construction: Clingy's GRDB never holds a byte of
  location data. Removing TraxKit removes *all* Trax data — no orphans, no migration
  entanglement.
- The host holds only transient runtime state: the latest in-memory fix, the
  currently-monitored region *set* (handed over by the kit), iOS's own auth/region
  tables. None of it is host app storage.

## The seam (the only thing between host and kit) — bidirectional

```swift
protocol TraxLocationHost: AnyObject {            // the host provides:
    var fixes: AsyncStream<TraxFix> { get }       //   live enriched device fixes
    var currentFix: TraxFix? { get }              //   snapshot (map dot, "use current location")
    var authorization: TraxLocationAuth { get }   //   observable auth state
    func requestLocationAccess()                  //   host owns the prompt
    func setMonitoredRegions(_ r: [TraxRegion])   //   kit hands its place-regions in
    func setDesiredTracking(_ d: TraxTrackingDemand) // kit's demand (.continuous/.significant/.off)
    var transitions: AsyncStream<TraxTransition> { get } // host geofence → kit
}

struct TraxFix {                 // exactly the PostTrack inputs — host assembles it
    let coordinate: CLLocationCoordinate2D
    let accuracy, altitude, speed, heading: Double?
    let motion: String?; let battery: Int?; let charging: Bool?  // device signals, host-owned
    let timestamp: Date
}
struct TraxRegion { let placeID: UUID; let center: CLLocationCoordinate2D; let radiusM: Double }
struct TraxTransition { let placeID: UUID; let event: TraxEvent /* enter|leave */ }
enum TraxTrackingDemand { case off, significant, continuous }
```

- **engine → kit:** enriched `TraxFix`, region crossings (`TraxTransition`), auth state.
- **kit → engine:** the regions to monitor, **and a location demand signal**.

The demand signal is the one place the kit's sharing-knowledge influences the
engine — but only as a *level*. The kit owns *sharing* (who's watching) and *upload*
cadence; it expresses its need as `.continuous/.significant/.off`, and the engine
decides *how* to satisfy it at the hardware level. **Sharing state never crosses
into the host.**

## The layer stack

```
HOST (TraxLab dev / Clingy prod)
  LocationHost impl            Chat adapter (Clingy only)        Session glue
  • CLLocationManager (single) • badge/card/thread-rows          • engine.start(userId)
  • rolling-20 geofence        • concentrated behind ext. points • engine.stop() on logout
  • motion+battery → TraxFix
        ▲ seam (fixes/transitions/auth ↑ ; regions/demand ↓)         ▲ bridge + mount
TraxKit (the rail — zero CoreLocation, zero chat knowledge)
  Seam:   TraxLocationHost protocol
  Engine: coordinator — owns store+sync+bridge, holds the seam, start/stop, mounts view
  Bridge: TraxLocationStore — relationship / summary / transitions / shared-places (reads)
  Sync:   drain feed→store · post fixes (while sharing, throttled) · post transitions
  Store:  per-user · App-Group · @Observable · VersionedSchema (the local mirror)
  Wire:   connect-swift client (codegen'd from .proto) + auth interceptor
  UI:     TraxRootView + hub/map/places/me/settings/share/onboarding
        │ Connect/protobuf
  mvTrax (connect-go, same store/fanout)
```

## The three data paths

- **Outbound (I share):** host CL → `TraxFix` → Sync poster (only while sharing,
  throttled) → `PostTrack` → mvTrax → fanout.
- **Inbound (I watch):** mvTrax → `Feed` (unary now; `Watch` stream later, same store)
  → Sync drain → Store → Bridge (`@Observable`) → host chat + kit map.
- **Geofence (I cross a place):** kit `regions` → host rolling-20 monitors → crossing
  → `TraxTransition` → Sync `PostTransition` → mvTrax → fanout → others' bridge → their chat.

## Cold-launch contract

Regions are kit-owned data, re-derived on launch. iOS's region table is OS
infrastructure (it persists + wakes the app on a crossing), **not host storage** — a
runtime cache the kit refills. On a cold background-launch:

> host wakes → recreates `CLLocationManager` → gets `didEnterRegion` (identifier =
> `placeID`) → **the kit must boot** (load the per-user SwiftData store, resolve the
> place) to record + post the transition, then re-hand the full region set.

The host can't resolve or persist a crossing on its own — it must bring the kit up.
This is what fixes the cold-launch event-loss; it's baked into the engine start path.

## Transport — Connect RPC / protobuf

Chat-independent (TraxKit owns both ends of its own wire; the host only hands it a
base URL + token). Decision driven by: a single `.proto` contract → codegen both
sides → DTO drift becomes a compile error; binary efficiency; and a free
server-streaming upgrade path (`Watch`) that replaces WS without new infra.

- **Unary polling now** (adaptive cadence), **server-streaming (`Watch`) later** —
  additive to the same `.proto` and store.
- One `.proto` lives in mvTrax (server-authoritative) → codegen connect-go (server)
  + connect-swift (kit).

## Store

Per-user file (`Trax-{userID}.store`), App-Group container
(`group.app.mvchat.Clingy3`), `@Observable`, `VersionedSchema` + `MigrationPlan`.
Identity-keyed so cross-account bleed is impossible by construction. The engine is
registered as a Clingy `SessionParticipant` (a thin host-side wrapper around
`start/stop`) so teardown rides Clingy's proven session edge.

## Embed surface

```swift
let engine = TraxEngine(config: TraxConfig(baseURL:, userID:, tokenProvider:),
                        locationHost: someHostImpl)   // TraxLab or Clingy
engine.start()                                        // on login
engine.bridge.relationship(with: partnerID)           // chat reads
TraxRootView(engine: engine)                          // the tab
engine.stop()                                         // on logout
```

The engine moves *into* TraxKit (today it's hand-rolled in the lab). Host supplies
config + the seam impl + lifecycle; the kit owns store/sync/bridge.

## Port-vs-rebuild inventory

| Piece | Disposition |
|---|---|
| `TraxTransport` (REST/JSON) | **rebuild** → connect-swift client + interceptor |
| `TraxStore` | **rebuild** → per-user, App-Group, `@Observable`, versioned |
| `TraxSync` | **rebuild** (logic ports) → drain + poster |
| `TraxLocationProducer` | **collapse** into Sync's poster (≈90% deleted) |
| `TraxGeofenceMonitor` | **delete** (host owns) |
| `TraxSelfState` | **delete** (host `currentFix`) |
| `TraxPermissions` | **delete** (host owns auth) |
| `TraxEngine` (lab) | **rebuild** into the kit as the coordinator |
| `DTOs` | **replace** with proto-gen types (+ a few hand bridge values) |
| `TraxLocationStore` (bridge) + read-models | **port** the shape, rewire to new store |
| UI (`TraxHub`*, `TraxMeView`, `TraxShareSheet`, `TraxSettingsView`, `TraxTimelineView`, `TraxOnboardingView`, `TraxUI`) | **port**, rewire reads |
| `TraxHubPlaces`/`PlaceEditor` + `AddressSearchModel` | **port**, rewire "use current location" → seam |
| `TraxGeocoder`, `TraxWeather*` | **port** as-is |
| `Models` (SwiftData entities) | **port** into the versioned schema |

Net: rebuild the spine (wire/store/sync/seam/engine, delete the 3 CL owners), carry
the UI + bridge + domain.

## Proto surface (derived — locked after the shape)

`PostTrack`, `Feed` (→ `Watch` stream later), `ListShares/StartShare/StopShare`,
`ListPlaces/Create/Update/Delete/Share/Unshare`, `PostTransition/ListTransitions`,
`Contacts`, `Weather`. Messages: `Fix`, `Share`, `Place`, `Transition`, `Contact`,
`FeedPage`.

## Repos / staging

- **mvTrax** (Go): evolve in place — add connect-go alongside REST, drop REST after.
- **TraxKit** (SPM) + **Demo/TraxLab**: the rail + the dev host. TraxLab reshaped to
  be a faithful Clingy-shaped host (location-engine seam impl + a minimal chat-like
  consumer + session lifecycle).
- **clingy-trax**: frozen on TraxKit `0.2.0` (remote tag) during the rebuild; later,
  swap the dependency + build the *concentrated* chat adapter + wire the kept-Tangle
  location engine into the seam.

## Open decisions

1. **Engine into the kit** (host gives config+seam+lifecycle) — leaning yes.
2. **TraxFix carries motion+battery** (host enriches) so the kit touches zero device
   APIs — leaning yes.
3. **Feed unary now, `Watch` stream later** (same store, additive proto) — leaning yes.
4. **Transitions as a first-class store entity** (vs the current transient buffer +
   durable read-back) — leaning yes (cleaner backfill, survives relaunch).
5. **Rewrite TraxKit in place vs greenfield TraxPlusKit** — TBD (this doc's next call).
