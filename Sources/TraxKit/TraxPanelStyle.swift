import SwiftUI

/// How the panels over the map are drawn (the hub's sheet, a person's card):
/// a viewing preference the person picks in the kit's Location settings, kept
/// per device. Clear glass takes on the map's colour; the others put a layer
/// between the map and the text, darker in Dark and lighter in Light, with a
/// whisper of the host's tint on the glass levels (as a host's own glass over
/// a busy wallpaper leans to its brand, not to grey). The small floating
/// controls stay clear glass whatever is chosen.
public enum TraxPanelStyle: String, CaseIterable, Identifiable, Sendable {
    case clear, smoked, strong, solid

    public var id: Self { self }

    /// The UserDefaults key the choice is kept under (the kit's prefix). A
    /// device preference, like the text size: not reset on sign-out.
    public static let storageKey = "trax.panelStyle"

    public var label: String {
        switch self {
        case .clear:  "Clear"
        case .smoked: "Smoked"
        case .strong: "Strong"
        case .solid:  "Solid"
        }
    }

    /// The stored choice, or the host's default when the person hasn't picked.
    static func resolved(stored: String?, default fallback: TraxPanelStyle) -> TraxPanelStyle {
        stored.flatMap(TraxPanelStyle.init(rawValue:)) ?? fallback
    }

    /// The layer over the map, per scheme: (white level, opacity) for the
    /// tinted glass levels; nil for clear.
    func layer(dark: Bool) -> (white: Double, opacity: Double)? {
        switch self {
        case .clear:  nil
        case .smoked: dark ? (0, 0.45) : (1, 0.6)
        case .strong: dark ? (0, 0.65) : (1, 0.8)
        case .solid:  dark ? (0, 0.35) : (1, 0.45)   // over a thick material
        }
    }

    /// Buttons inside the panel: glass on clear glass, a plain fill on the
    /// layered levels (no glass on glass).
    var buttonsAreGlass: Bool { self == .clear }
}

extension EnvironmentValues {
    /// The panel style around this view (set by the panel; clear elsewhere).
    @Entry var traxPanelStyle: TraxPanelStyle = .clear
}

/// The panel's surface for `style`, in `shape`.
struct TraxPanelSurface<S: Shape>: View {
    /// The host's tint over the layered glass: enough to read as the host's,
    /// too little to move the text contrast (PanelStyleTests).
    static var brandWhisper: Double { 0.08 }
    let style: TraxPanelStyle
    let shape: S
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let layer = style.layer(dark: scheme == .dark).map { Color(white: $0.white).opacity($0.opacity) }
        switch style {
        case .clear:
            Color.clear.glassEffect(.regular, in: shape)
        case .smoked, .strong:
            ZStack {
                Color.clear.glassEffect(.regular.tint(layer), in: shape)
                shape.fill(.tint.opacity(Self.brandWhisper))
            }
        case .solid:
            ZStack {
                shape.fill(.ultraThickMaterial)
                if let layer { shape.fill(layer) }
            }
        }
    }
}

/// Reads the person's choice (or the host's default) for a panel.
struct TraxPanelStyleReader<Content: View>: View {
    let fallback: TraxPanelStyle
    @ViewBuilder let content: (TraxPanelStyle) -> Content
    @AppStorage(TraxPanelStyle.storageKey) private var stored: String?

    var body: some View {
        let style = TraxPanelStyle.resolved(stored: stored, default: fallback)
        content(style).environment(\.traxPanelStyle, style)
    }
}

/// Secondary and destructive actions read the panel they sit in.
struct TraxPanelButtonStyle: ViewModifier {
    @Environment(\.traxPanelStyle) private var panel
    func body(content: Content) -> some View {
        if panel.buttonsAreGlass {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered).tint(Color.primary.opacity(0.6))
        }
    }
}
