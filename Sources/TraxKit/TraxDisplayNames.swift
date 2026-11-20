import SwiftUI

/// What the host calls people. A host that keeps its own names (a nickname, a
/// contact card) hands them to the kit so a person's map, pair settings and
/// lists read the same as the rest of the host. Return nil (or an empty string)
/// to use the kit's people directory.
public struct TraxDisplayNames: Sendable {
    let resolve: @MainActor @Sendable (UUID) -> String?

    public init(_ resolve: @escaping @MainActor @Sendable (UUID) -> String?) {
        self.resolve = resolve
    }

    /// No host names: the directory alone.
    public static let directory = TraxDisplayNames { _ in nil }

    /// The name to show for `id`: the host's, else the directory's, else
    /// `fallback` (a neutral "Member …" by default). Never empty.
    @MainActor
    func name(for id: UUID, people: [UUID: TraxContact], fallback: String? = nil) -> String {
        if let n = resolve(id), !n.isEmpty { return n }
        if let n = people[id]?.name, !n.isEmpty { return n }
        return fallback ?? Self.fallback(id)
    }

    static func fallback(_ id: UUID) -> String { "Member \(id.uuidString.prefix(8))" }
}

extension EnvironmentValues {
    @Entry var traxDisplayNames: TraxDisplayNames = .directory
}

public extension View {
    /// Name people in the kit's views as the host does. The closure runs while
    /// a view draws, so reading observable host state there keeps names live.
    func traxDisplayNames(_ name: @escaping @MainActor @Sendable (UUID) -> String?) -> some View {
        environment(\.traxDisplayNames, TraxDisplayNames(name))
    }
}
