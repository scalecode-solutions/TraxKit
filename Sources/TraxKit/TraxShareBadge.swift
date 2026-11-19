import SwiftUI

/// Which way location sharing goes with one person, as a small badge for a
/// conversation list or header. Shape and color both differ per direction, so
/// it reads without relying on tint. Nothing renders when neither shares.
public struct TraxShareBadge: View {
    let engine: TraxEngine
    let otherID: UUID
    /// Header glass: a brighter tint and a faint shadow, readable on any backdrop.
    let bright: Bool
    @ScaledMetric private var size: CGFloat

    /// `size` is the base point size at the default text size; it scales with
    /// Dynamic Type.
    public init(engine: TraxEngine, otherID: UUID, size: CGFloat = 13, bright: Bool = false) {
        self.engine = engine
        self.otherID = otherID
        self.bright = bright
        _size = ScaledMetric(wrappedValue: size, relativeTo: .caption)
    }

    public var body: some View {
        if let d = TraxShareDirection(engine.relationship(with: otherID)) {
            Image(systemName: d.symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(bright ? AnyShapeStyle(d.brightTint) : d.tint)
                .shadow(color: bright ? .black.opacity(0.3) : .clear, radius: 1, y: 0.5)
                .accessibilityLabel(d.accessibilityLabel)
                .accessibilityIdentifier("trax.shareBadge")
        }
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

    var symbol: String {
        switch self {
        case .iShare:    "location.circle.fill"           // my location going out
        case .theyShare: "mappin.circle.fill"             // theirs coming in
        case .both:      "arrow.up.arrow.down.circle.fill"
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
