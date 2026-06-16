import SwiftUI
import SwiftData

/// The whole TraxKit experience as one droppable view — the standalone app.
/// TraxLab renders this; Clingy can later embed it wholesale OR weave the
/// composable pieces (`TraxMapView`, `TraxPlacesView`, `TraxSettingsView`) into
/// its own chrome. Owns the single sync engine, the location producer, and the
/// poll loop; injects the SwiftData container into the whole tree.
///
/// (Tab scaffold for now — every feature lands in its real home. The Map tab can
/// evolve into a Life360-style map + member carousel without disturbing the rest.)
public struct TraxRootView: View {
    private let store: TraxStore
    private let onSignOut: (() -> Void)?
    @State private var sync: TraxSync
    @State private var producer: TraxLocationProducer

    /// `onSignOut`, when provided, surfaces a Sign Out control in the Me tab. The
    /// host owns the auth action; the SPM owns the chrome.
    public init(config: TraxConfig, store: TraxStore, onSignOut: (() -> Void)? = nil) {
        self.store = store
        self.onSignOut = onSignOut
        let s = TraxSync(config: config, store: store)
        _sync = State(initialValue: s)
        _producer = State(initialValue: TraxLocationProducer { body in
            try? await s.track(body)
        })
    }

    public var body: some View {
        TabView {
            Tab("Map", systemImage: "map") {
                NavigationStack { TraxMapView(sync: sync).traxInlineNavTitle("Trax") }
            }
            Tab("Places", systemImage: "mappin.and.ellipse") {
                NavigationStack { TraxPlacesView(sync: sync).traxInlineNavTitle("Places") }
            }
            Tab("Me", systemImage: "person.crop.circle") {
                NavigationStack { TraxSettingsView(sync: sync, onSignOut: onSignOut).traxInlineNavTitle("Me") }
            }
        }
        .modelContainer(store.container)
        .task { await runLoop() }
        .onDisappear { producer.stop() }
    }

    /// Start producing, then keep the feed + outgoing shares fresh on a 5s poll.
    /// `.task` cancels when the root disappears.
    private func runLoop() async {
        producer.start()
        await sync.loadContacts()
        await sync.refresh()
        await sync.refreshOutgoing()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { break }
            await sync.refresh()
            await sync.refreshOutgoing()
        }
    }
}
