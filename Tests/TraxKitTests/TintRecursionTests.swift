import Foundation
import Testing

/// No view or map content may set its tint in terms of the tint
/// (`.tint(.tint…)`): SwiftUI resolves that tint against itself and recurses
/// until the stack runs out. On iOS 27 it crashed the person map on a real
/// iPhone when a shared place's marker drew (MVTRAX-43). Fill and foreground
/// styles of `.tint` are fine: they read the host's tint, they don't set it.
@Suite struct TintRecursionTests {
    @Test func nothingSetsTheTintFromTheTint() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TraxKit")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "no kit sources found at \(sources.path)")
        // One line at a time: a `.tint(` with its argument on the next line
        // would slip past. Keep tint calls on one line.
        let pattern = try Regex(#"\.tint\(\s*(AnyShapeStyle\(\s*)?\.tint\b"#)
        var hits: [String] = []
        for file in files {
            for (n, line) in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(pattern) {
                hits.append("\(file.lastPathComponent):\(n + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(hits.isEmpty, "the tint set from the tint (recursion):\n\(hits.joined(separator: "\n"))")
    }
}
