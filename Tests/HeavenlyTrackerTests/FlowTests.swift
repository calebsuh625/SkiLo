import Foundation
import Testing
@testable import HeavenlyTracker

@MainActor
@Suite struct FlowTests {
    @Test func badgeIgnoresUnknownIds() throws {
        var d = Fixtures.userData(bucket: ["t-gunbarrel", "ghost-1", "ghost-2"])
        d.profile.onboardingDone = true
        let store = try Fixtures.makeStore(userData: d)
        #expect(store.bucketPending.count == 3)
        #expect(store.bucketBadgeCount == 1)
    }

    @Test func logRunUpdatesLogTimesSkiedAndHistory() throws {
        let store = try Fixtures.makeStore()
        let id = "t-gunbarrel"
        store.logRun(RunLogEntry(trailID: id, date: Date()), alsoMarkDone: true)
        #expect(store.userData.runLog.count == 1)
        #expect(store.userData.runLog[0].isFirstTime)
        #expect(store.state(for: id).timesSkied == 1)
        #expect(store.state(for: id).isDone)
        #expect(!store.userData.profile.skillHistory.isEmpty)
        store.logRun(RunLogEntry(trailID: id, date: Date()), alsoMarkDone: true)
        #expect(store.state(for: id).timesSkied == 2)
        #expect(store.userData.runLog.count == 2)
    }

    @Test func moveBucketReorders() throws {
        let ids = Array(try Fixtures.bundledCatalog().trails.prefix(3).map(\.id))
        let store = try Fixtures.makeStore(userData: Fixtures.userData(bucket: ids))
        store.moveBucket(from: IndexSet(integer: 0), to: 3)
        #expect(store.bucketPending == [ids[1], ids[2], ids[0]])
    }

    @Test func exportImportRoundTrip() throws {
        let store = try Fixtures.makeStore(userData: Fixtures.userData(done: ["t-gunbarrel"], bucket: ["t-the-face"]))
        store.logRun(RunLogEntry(trailID: "t-gunbarrel", date: Date()), alsoMarkDone: false)
        let dir = try TestPaths.scratchDirectory("roundtrip")
        let url = dir.appendingPathComponent("x.json")
        try ExportImport.export(store.userData, to: url)
        let (back, _) = try ExportImport.read(from: url)   // dates are stored to whole seconds
        let url2 = dir.appendingPathComponent("y.json")
        try ExportImport.export(back, to: url2)
        let (back2, _) = try ExportImport.read(from: url2)
        #expect(back2.trailStates == back.trailStates)
        #expect(back2.runLog == back.runLog)
        #expect(back2.bucketOrder == store.userData.bucketOrder)
        #expect(back2.profile.skillHistory == back.profile.skillHistory)
        #expect(back.runLog.map(\.id) == store.userData.runLog.map(\.id))
        #expect(back.trailStates.mapValues(\.status) == store.userData.trailStates.mapValues(\.status))
        #expect(back.trailStates["t-gunbarrel"]?.timesSkied == 2)
    }
}
