import Foundation
import Testing
@testable import TraxKit

/// `TraxConfig.storeDirectory`: the host can say where the store lives (e.g. a
/// folder it keeps out of device backups), and the files land there.
@MainActor
@Suite struct StoreLocationTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "TraxStoreLocationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func storeLandsInTheGivenDirectoryAndCreatesIt() {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appending(path: "Nested/Trax", directoryHint: .isDirectory)
        let user = UUID()

        let store = TraxStore(userID: user, directory: dir)
        store.setCursor(42)
        store.save()

        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "Trax-\(user.uuidString).store").path))
        #expect(store.cursor() == 42)
    }

    @Test func reopeningTheSameDirectoryKeepsTheData() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let user = UUID()
        do {
            let store = TraxStore(userID: user, directory: dir)
            store.setCursor(7)
            store.save()
        }
        #expect(TraxStore(userID: user, directory: dir).cursor() == 7)
    }

    @Test func eachAccountGetsItsOwnFileInTheDirectory() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = UUID(), b = UUID()
        let sa = TraxStore(userID: a, directory: dir); sa.setCursor(1); sa.save()
        let sb = TraxStore(userID: b, directory: dir)
        #expect(sb.cursor() == 0)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "Trax-\(a.uuidString).store").path))
    }

    @Test func configCarriesTheDirectoryAndDefaultsToNil() {
        let dir = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        let url = URL(string: "https://example.com")!
        #expect(TraxConfig(baseURL: url, currentUserID: UUID(), tokenProvider: { nil }, storeDirectory: dir).storeDirectory == dir)
        #expect(TraxConfig(baseURL: url, currentUserID: UUID(), tokenProvider: { nil }).storeDirectory == nil)
    }
}
