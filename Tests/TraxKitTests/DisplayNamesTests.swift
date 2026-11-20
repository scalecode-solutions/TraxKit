import Foundation
import SwiftUI
import Testing
@testable import TraxKit

/// Whose name a person gets: the host's first, then the people directory,
/// then a neutral fallback.
@MainActor
@Suite struct DisplayNamesTests {
    let sam = UUID(), stranger = UUID()
    var people: [UUID: TraxContact] { [sam: TraxContact(id: sam, name: "Sam Reed")] }

    @Test func theHostsNameWins() {
        let names = TraxDisplayNames { $0 == sam ? "Sunny" : nil }
        #expect(names.name(for: sam, people: people) == "Sunny")
    }

    @Test func noHostNameUsesTheDirectory() {
        #expect(TraxDisplayNames.directory.name(for: sam, people: people) == "Sam Reed")
        let names = TraxDisplayNames { _ in "" }   // empty counts as none
        #expect(names.name(for: sam, people: people) == "Sam Reed")
    }

    @Test func nobodyKnowsThemFallsBack() {
        let n = TraxDisplayNames.directory.name(for: stranger, people: people)
        #expect(n == "Member \(stranger.uuidString.prefix(8))")
        #expect(TraxDisplayNames.directory.name(for: stranger, people: [:], fallback: "You") == "You")
        let blank = [stranger: TraxContact(id: stranger, name: "")]
        #expect(TraxDisplayNames.directory.name(for: stranger, people: blank, fallback: "You") == "You")
    }

    @Test func theEnvironmentDefaultIsTheDirectory() {
        let env = EnvironmentValues().traxDisplayNames
        #expect(env.name(for: sam, people: people) == "Sam Reed")
    }
}
