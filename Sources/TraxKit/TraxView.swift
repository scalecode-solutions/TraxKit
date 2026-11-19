import SwiftUI

/// What a host shows: everyone's locations, or one person's.
public enum TraxFocus: Hashable, Sendable {
    /// The hub: everyone sharing with me, my places, the weather.
    case everyone
    /// One person: their location, my share to them, our places.
    case person(UUID)
}

/// The kit's wording, chosen by the host. Neutral defaults; a host passes its own.
/// Strings with `%@` take the person's name.
public struct TraxAppearance: Sendable {
    public var notSharing: String
    public var shareButton: String
    public var sharingWith: String
    public var placesTogether: String
    public var stopAllSharing: String
    public var clearHistory: String
    /// The footer under location access in TraxSettingsView.
    public var accessFooter: String

    public init(notSharing: String = "%@ isn't sharing their location",
                shareButton: String = "Share My Location with %@",
                sharingWith: String = "Sharing your location",
                placesTogether: String = "Places shared with %@",
                stopAllSharing: String = "Stop sharing with everyone",
                clearHistory: String = "Clear location history",
                accessFooter: String = "Location is only used while you share it with someone, or for arrivals at your places.") {
        self.notSharing = notSharing
        self.shareButton = shareButton
        self.sharingWith = sharingWith
        self.placesTogether = placesTogether
        self.stopAllSharing = stopAllSharing
        self.clearHistory = clearHistory
        self.accessFooter = accessFooter
    }

    public static let standard = TraxAppearance()

    func with(_ format: String, _ name: String) -> String {
        format.replacingOccurrences(of: "%@", with: name)
    }
}

/// The location surface. `.everyone` is the hub (a map with people, weather and
/// places in a sheet); `.person(id)` is one person's map with a card of what
/// you two share. The kit owns its content; the HOST owns the navigation bar
/// and starts and stops the engine (and holds it while this is on screen, so
/// the feed polls fast).
///
/// **It must sit inside a `NavigationStack`**: the person map sets its title
/// there, and the hub pushes history and weather onto it.
public struct TraxView: View {
    let engine: TraxEngine
    let appearance: TraxAppearance
    private let hostFocus: Binding<TraxFocus>?

    /// `focus`: nil shows everyone. A conversation passes
    /// `.constant(.person(theirID))`.
    public init(engine: TraxEngine, appearance: TraxAppearance = .standard, focus: Binding<TraxFocus>? = nil) {
        self.engine = engine
        self.appearance = appearance
        self.hostFocus = focus
    }

    private var focus: TraxFocus { hostFocus?.wrappedValue ?? .everyone }

    public var body: some View {
        switch focus {
        case .everyone:
            TraxHub(engine: engine, embedded: true)
                .background { RegionSyncer(engine: engine) }
        case .person(let id):
            TraxPersonMap(engine: engine, personID: id, appearance: appearance)
        }
    }
}
