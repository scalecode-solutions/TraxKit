import SwiftUI
import SwiftData

/// Saved places (home/work/custom), shared with friends, with arrival/departure
/// alerts. Composable piece hosted in the Places tab.
///
/// Scaffold — the places domain (server tables, `transition` events, geofence
/// monitoring) is the next piece to build. This is its real home so the feature
/// lands here without retrofitting.
public struct TraxPlacesView: View {
    let sync: TraxSync
    public init(sync: TraxSync) { self.sync = sync }

    public var body: some View {
        List {
            Section {
                ContentUnavailableView {
                    Label("No places yet", systemImage: "mappin.slash")
                } description: {
                    Text("Save Home, Work, or any spot — and get notified when the people sharing with you arrive or leave.")
                }
            }
        }
    }
}
