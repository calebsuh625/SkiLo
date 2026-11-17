import Foundation
import Testing
@testable import HeavenlyTracker

enum TestPaths {
    /// Repo root derived from this file's compile-time path (works in copies of the tree too).
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func data(_ relative: String) -> URL { repoRoot.appendingPathComponent("data").appendingPathComponent(relative) }
    static func scratchDirectory(_ name: String) throws -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("HeavenlyTrackerTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

enum Fixtures {
    static func bundledCatalog() throws -> TrailCatalog { try CatalogLoader.loadBundled() }
    static func userData(done: [Trail.ID] = [], bucket: [Trail.ID] = []) -> UserData {
        var d = UserData.fresh()
        for id in done { var s = UserTrailState(); s.status = .done; s.firstDoneDate = Date(); s.lastDoneDate = Date(); s.timesSkied = 1; d.trailStates[id] = s }
        for id in bucket { var s = d.state(for: id); s.bucketedAt = Date(); if s.status == .notDone { s.status = .bucket }; d.trailStates[id] = s; d.bucketOrder.append(id) }
        d.profile.onboardingDone = true
        return d
    }
    @MainActor
    static func makeStore(userData: UserData = Fixtures.userData()) throws -> AppStore {
        AppStore(catalog: try bundledCatalog(), userData: userData, persistence: nil)
    }
}
