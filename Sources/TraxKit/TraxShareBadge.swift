import SwiftUI

/// Which way location sharing goes with one person, as a small badge for a
/// conversation list or header. Shape and color both differ per direction, so
/// it reads without relying on tint. Nothing renders when neither shares.
/// A host can supply its own glyphs with `.traxShareGlyphs(_:)`.
public struct TraxShareBadge: View {
    let engine: TraxEngine
    let otherID: UUID
    /// Header glass: a brighter tint and a faint shadow, readable on any backdrop.
    let bright: Bool
    let maxSize: CGFloat
    @ScaledMetric private var size: CGFloat
    @Environment(\.traxShareGlyphs) private var glyphs

    /// `size` is the base point size at the default text size; it scales with
    /// Dynamic Type up to `maxSize` (1.5 × `size` when nil), so it stays a
    /// badge beside large text rather than growing into an icon.
    public init(engine: TraxEngine, otherID: UUID, size: CGFloat = 13, maxSize: CGFloat? = nil,
                bright: Bool = false) {
        self.engine = engine
        self.otherID = otherID
        self.bright = bright
        self.maxSize = max(size, maxSize ?? size * 1.5)
        _size = ScaledMetric(wrappedValue: size, relativeTo: .caption)
    }

    public var body: some View {
        if let d = TraxShareDirection(engine.relationship(with: otherID)) {
            glyphs.glyph(for: d).image
                .font(.system(size: min(size, maxSize), weight: .semibold))
                .foregroundStyle(bright ? AnyShapeStyle(d.brightTint) : d.tint)
                .shadow(color: bright ? .black.opacity(0.3) : .clear, radius: 1, y: 0.5)
                .accessibilityLabel(d.accessibilityLabel)
                .accessibilityIdentifier("trax.shareBadge")
        }
    }
}

/// One badge glyph: an SF Symbol, or a symbol image from the host's asset
/// catalog (a custom `.symbolset`, so it takes the font size and tint).
public struct TraxShareGlyph: Sendable, Hashable {
    enum Source: Sendable, Hashable { case system(String), asset(String, Bundle?) }
    let source: Source

    public static func system(_ name: String) -> TraxShareGlyph { .init(source: .system(name)) }
    /// `bundle` nil is the main bundle.
    public static func asset(_ name: String, bundle: Bundle? = nil) -> TraxShareGlyph {
        .init(source: .asset(name, bundle))
    }

    var image: Image {
        switch source {
        case .system(let name): Image(systemName: name)
        case .asset(let name, let bundle): Image(name, bundle: bundle)
        }
    }
}

/// The badge's three glyphs, one per direction. Keep them distinct in shape,
/// not only colour: the badge must read without its tint.
public struct TraxShareGlyphs: Sendable, Hashable {
    /// I share my location with them.
    public var outgoing: TraxShareGlyph
    /// They share theirs with me.
    public var incoming: TraxShareGlyph
    public var both: TraxShareGlyph

    public init(outgoing: TraxShareGlyph, incoming: TraxShareGlyph, both: TraxShareGlyph) {
        self.outgoing = outgoing; self.incoming = incoming; self.both = both
    }

    public static let standard = TraxShareGlyphs(
        outgoing: .system("location.circle.fill"),        // my location going out
        incoming: .system("mappin.circle.fill"),          // theirs coming in
        both: .system("arrow.up.arrow.down.circle.fill"))

    func glyph(for d: TraxShareDirection) -> TraxShareGlyph {
        switch d {
        case .iShare:    outgoing
        case .theyShare: incoming
        case .both:      both
        }
    }
}

extension EnvironmentValues {
    @Entry var traxShareGlyphs: TraxShareGlyphs = .standard
}

public extension View {
    /// The host's own glyphs for every `TraxShareBadge` below this view.
    func traxShareGlyphs(_ glyphs: TraxShareGlyphs) -> some View {
        environment(\.traxShareGlyphs, glyphs)
    }
}

/// The direction of a relationship, or nil when neither side shares.
enum TraxShareDirection: Equatable {
    case iShare, theyShare, both

    init?(_ rel: TraxRelationship) {
        switch (rel.iShare, rel.theyShare) {
        case (true, true):   self = .both
        case (true, false):  self = .iShare
        case (false, true):  self = .theyShare
        case (false, false): return nil
        }
    }

    /// Mine going out wears the host's tint; theirs coming in is green.
    var tint: AnyShapeStyle {
        switch self {
        case .iShare, .both: AnyShapeStyle(.tint)
        case .theyShare:     AnyShapeStyle(.green)
        }
    }

    var brightTint: Color {
        switch self {
        case .theyShare:     Color(red: 0.30, green: 0.90, blue: 0.46)
        case .iShare, .both: Color(red: 0.40, green: 0.72, blue: 1.0)
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .iShare:    "Sharing your location with them"
        case .theyShare: "They're sharing their location"
        case .both:      "Sharing location both ways"
        }
    }
}
