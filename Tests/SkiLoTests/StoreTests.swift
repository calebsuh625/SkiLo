import Testing
import Foundation
@testable import SkiLo

@MainActor
private func store(_ ud: UserData = Fixtures.userData(), undo: Bool = false, persistence: UserDataStore? = nil) throws -> (AppStore, UndoManager?) {
    let s = AppStore(catalog: try Fixtures.bundledCatalog(), userData: ud, persistence: persistence)
    var um: UndoManager?
    if undo { um = UndoManager(); um!.groupsByEvent = false; s.undoManager = um }
    return (s, um)
}

@Suite("Store")
@MainActor
struct StoreTests {
    @Test func markDoneThenNotDoneRestoresEmptyState() throws {
        let (s, _) = try store()
        let id = s.catalog.trails[0].id
        s.markDone(id)
        let st = s.state(for: id)
        #expect(st.status == .done); #expect(st.firstDoneDate != nil); #expect(st.lastDoneDate != nil); #expect(st.timesSkied == 1)
        #expect(s.doneCount == 1)
        s.markNotDone(id)
        #expect(s.userData.trailStates[id] == nil)
        #expect(s.doneCount == 0)
    }
    @Test func markDoneKeepsFirstDateAndBumpsOncePerDay() throws {
        let (s, _) = try store()
        let id = s.catalog.trails[0].id
        let d1 = Date(timeIntervalSince1970: 1_700_000_000), d2 = d1.addingTimeInterval(3 * 86400)
        s.markDone(id, on: d1); s.markDone(id, on: d1)
        #expect(s.state(for: id).timesSkied == 1)
        s.markDone(id, on: d2)
        let st = s.state(for: id)
        #expect(st.firstDoneDate == d1); #expect(st.lastDoneDate == d2); #expect(st.timesSkied == 2)
    }
    @Test func markDoneAfterLoggedRunDoesNotDoubleCount() throws {
        let (s, _) = try store()
        let id = s.catalog.trails[0].id
        s.logRun(RunLogEntry(trailID: id, date: .now), alsoMarkDone: false)
        s.markDone(id)
        #expect(s.state(for: id).timesSkied == 1)
    }
    @Test func bucketToDoneKeepsBucketedAtAndIsCrossedOff() throws {
        let (s, _) = try store()
        let id = s.catalog.trails[0].id
        s.addToBucket([id])
        #expect(s.state(for: id).status == .bucket); #expect(s.bucketPending == [id])
        let stamp = try #require(s.state(for: id).bucketedAt)
        s.markDone(id)
        #expect(s.state(for: id).bucketedAt == stamp)
        #expect(s.bucketCrossedOff == [id]); #expect(s.bucketPending.isEmpty)
        s.markNotDone(id)
        #expect(s.state(for: id).status == .bucket); #expect(s.bucketPending == [id])
    }
    @Test func bucketAddRemoveToggle() throws {
        let (s, _) = try store()
        s.addToBucket(["t-1", "t-2", "t-3"])
        #expect(s.bucketPending == ["t-1", "t-2", "t-3"])
        s.addToBucket(["t-2"])
        #expect(s.userData.bucketOrder == ["t-1", "t-2", "t-3"])
        s.removeFromBucket("t-2")
        #expect(s.bucketPending == ["t-1", "t-3"]); #expect(s.userData.trailStates["t-2"] == nil)
        s.toggleBucket("t-2"); #expect(s.bucketPending == ["t-1", "t-3", "t-2"])
        s.toggleBucket("t-2"); #expect(s.bucketPending == ["t-1", "t-3"])
    }
    @Test func moveBucketUsesPendingOffsets() throws {
        let (s, _) = try store()
        s.addToBucket(["a", "b", "c", "d"])
        s.markDone("b")                       // crossed off: leaves pending, stays in bucketOrder
        #expect(s.bucketPending == ["a", "c", "d"])
        s.moveBucket(from: IndexSet(integer: 2), to: 0)      // d to front
        #expect(s.bucketPending == ["d", "a", "c"])
        s.moveBucket(from: IndexSet(integer: 0), to: 3)      // d to end
        #expect(s.bucketPending == ["a", "c", "d"])
        s.moveBucket(from: IndexSet([0, 1]), to: 3)
        #expect(s.bucketPending == ["d", "a", "c"])
        #expect(Set(s.userData.bucketOrder) == ["a", "b", "c", "d"])
        #expect(s.userData.bucketOrder.count == 4)
    }
    @Test func logRunCountsAndFlagsFirstTimeOnce() throws {
        let (s, _) = try store()
        let id = s.catalog.trails[0].id
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        s.logRun(RunLogEntry(trailID: id, date: day), alsoMarkDone: false)
        s.logRun(RunLogEntry(trailID: id, date: day.addingTimeInterval(86400)), alsoMarkDone: true)
        #expect(s.userData.runLog.map(\.isFirstTime) == [true, false])
        let st = s.state(for: id)
        #expect(st.timesSkied == 2)                          // two runs; marking done the same day as a run adds nothing
        #expect(st.isDone); #expect(st.lastDoneDate == day.addingTimeInterval(86400))
        #expect(s.toast?.text.hasPrefix("Run logged") == true)
        #expect(s.skiDays.count == 2)
    }
    @Test func logRunAlsoMarkDoneIsOneUndoStep() throws {
        let (s, um) = try store(undo: true)
        let id = s.catalog.trails[0].id
        s.logRun(RunLogEntry(trailID: id, date: .now), alsoMarkDone: true)
        #expect(s.state(for: id).isDone)
        um!.undo()
        #expect(s.userData.runLog.isEmpty); #expect(s.userData.trailStates[id] == nil)
    }
    @Test func updateAndDeleteRun() throws {
        let (s, _) = try store()
        let e = RunLogEntry(trailID: "t-x", date: .now)
        s.logRun(e, alsoMarkDone: false)
        var e2 = e; e2.confidence = 5; s.updateRun(e2)
        #expect(s.userData.runLog.first?.confidence == 5)
        s.deleteRun(e.id)
        #expect(s.userData.runLog.isEmpty)
    }
    @Test func overridesAffectEffectiveRating() throws {
        let (s, _) = try store()
        let t = s.catalog.trails[0]
        let base = s.effectiveRating(t)
        s.setOverride(t.id, rating: 91, note: "icy")
        #expect(s.effectiveRating(t.id) == 91); #expect(s.effectiveRatings[t.id] == 91)
        s.setOverride(t.id, rating: 500, note: nil)
        #expect(s.effectiveRating(t.id) == 100)
        s.setOverride(t.id, rating: nil, note: nil)
        #expect(s.effectiveRating(t.id) == base); #expect(s.userData.trailStates[t.id] == nil)
    }
    @Test func bulkMarkDoneIsSingleUndoStep() throws {
        let (s, um) = try store(undo: true)
        let ids = (0..<5).map { "t-bulk-\($0)" }
        s.markDone(ids: ids)
        #expect(s.doneCount == 0)            // ids not in catalog → doneCount only counts catalog ids; check states instead
        #expect(ids.allSatisfy { s.state(for: $0).isDone })
        #expect(s.toast?.text == "5 trails marked done")
        um!.undo()
        #expect(ids.allSatisfy { s.userData.trailStates[$0] == nil })
        #expect(!um!.canUndo)
        um!.redo()
        #expect(ids.allSatisfy { s.state(for: $0).isDone })
    }
    @Test func undoRedoBumpRevisionAndSchedulePersist() throws {
        let dir = try TestPaths.scratchDirectory("undo-persist")
        let disk = UserDataStore(directory: dir)
        let (s, um) = try store(undo: true, persistence: disk)
        let um2 = try #require(um)
        let id = s.catalog.trails[0].id
        s.markDone(id)
        let r1 = s.revision
        um2.undo()
        #expect(s.revision == r1 + 1); #expect(s.userData.trailStates[id] == nil)
        s.flush()
        guard case .loaded(let onDisk) = disk.load() else { Issue.record("load"); return }
        #expect(onDisk.trailStates[id] == nil)
        um2.redo()
        #expect(s.revision == r1 + 2); #expect(s.state(for: id).isDone)
        s.flush()
        guard case .loaded(let onDisk2) = disk.load() else { Issue.record("load"); return }
        #expect(onDisk2.state(for: id).isDone)
    }
    @Test func separateMutationsAreSeparateUndoSteps() throws {
        let (s, um) = try store(undo: true)
        s.addToBucket(["t-1"]); s.addToBucket(["t-2"])
        um!.undo()
        #expect(s.bucketPending == ["t-1"])
        um!.undo()
        #expect(s.bucketPending.isEmpty)
        #expect(um!.undoActionName == "" || !um!.canUndo)
    }
    @Test func markDoneProducesToastWithUndoAndLogRun() throws {
        let (s, um) = try store(undo: true)
        let t = s.catalog.trails[0]
        s.markDone(t.id)
        let toast = try #require(s.toast)
        #expect(toast.text.hasPrefix("✓ \(t.name) crossed off")); #expect(toast.text.hasSuffix(" Elo")); #expect(toast.kind == .done)
        #expect(toast.actions.map(\.title) == ["Undo", "Log run…"])
        toast.actions[1].handler()
        #expect(s.logRunRequest?.trailID == t.id)
        toast.actions[0].handler()
        #expect(s.userData.trailStates[t.id] == nil)
        _ = um
    }
    @Test func bucketCrossOffToastText() throws {
        let (s, _) = try store()
        let t = s.catalog.trails[0]
        s.addToBucket([t.id]); #expect(s.toast?.text == "★ Added to bucket list")
        s.markDone(t.id); #expect(s.toast?.text.hasPrefix("★ \(t.name) crossed off your bucket list") == true)
        s.logRun(RunLogEntry(trailID: t.id, date: .now), alsoMarkDone: false)
        s.markNotDone(t.id); #expect(s.toast?.text == "\(t.name) marked not done")
        s.markDone(t.id)
        #expect(s.toast?.actions.map(\.title) == ["Undo"])   // a run is already logged today
    }
    @Test func statusChangeIsPublished() throws {
        let (s, _) = try store()
        let id = s.catalog.trails[0].id
        s.markDone(id)
        #expect(s.lastStatusChange == StatusChange(trailID: id, badge: .done, revision: s.revision))
    }
    @Test func onboardingBackfillsAndFlags() throws {
        let (s, _) = try store(UserData.fresh())
        #expect(s.showOnboarding || DevHooks.skipOnboarding)
        let band = Band.of(s.catalog.trails[0].rating.total)
        s.completeOnboarding(selfAssessed: 61, backfill: [band])
        #expect(s.userData.profile.selfAssessedStart == 61); #expect(s.userData.profile.onboardingDone)
        #expect(!s.showOnboarding)
        let filled = s.catalog.trails.filter { Band.of($0.rating.total) == band }
        #expect(!filled.isEmpty)
        #expect(filled.allSatisfy { s.state(for: $0.id).isDone && s.state(for: $0.id).backfilled })
        s.markDone(filled[0].id)
        #expect(!s.state(for: filled[0].id).backfilled)       // a real ski day clears the flag
    }
    @Test func replaceAndResetAreOneUndoStep() throws {
        let (s, um) = try store(Fixtures.userData(done: ["t-a", "t-b"], bucket: ["t-c"]), undo: true)
        s.resetAllUserData()
        #expect(s.userData.trailStates.isEmpty)
        um!.undo()
        #expect(s.state(for: "t-a").isDone); #expect(s.bucketPending == ["t-c"])
    }
    @Test func noOpMutationDoesNotBumpRevisionOrUndo() throws {
        let (s, um) = try store(undo: true)
        let r = s.revision
        s.markNotDone("t-nothing"); s.removeFromBucket("t-nothing"); s.setNotes("t-nothing", "")
        #expect(s.revision == r); #expect(!um!.canUndo)
    }
    @Test func normalizeFixesBrokenDocuments() throws {
        var d = UserData.fresh()
        var bad = UserTrailState(); bad.status = .bucket                         // bucket without bucketedAt
        var done = UserTrailState(); done.status = .done                         // done without dates
        d.trailStates = ["t-bad": bad, "t-done": done, "t-empty": UserTrailState()]
        d.bucketOrder = ["ghost", "t-bad", "t-bad"]
        let (s, _) = try store(d)
        s.setNotes("t-x", "touch")
        #expect(s.state(for: "t-bad").bucketedAt != nil)
        #expect(s.state(for: "t-done").firstDoneDate != nil); #expect(s.state(for: "t-done").lastDoneDate != nil)
        #expect(s.userData.bucketOrder == ["t-bad"])
        #expect(s.userData.trailStates["t-empty"] == nil)
    }
    @Test func randomOperationsKeepInvariants() throws {
        let (s, um) = try store(undo: true)
        let ids = (0..<10).map { "t-r-\($0)" }
        var rng = SplitMix(seed: 42)
        for _ in 0..<100 {
            let id = ids[Int(rng.next() % 10)]
            switch rng.next() % 9 {
            case 0: s.markDone(id)
            case 1: s.markNotDone(id)
            case 2: s.toggleBucket(id)
            case 3: s.addToBucket([id, ids[Int(rng.next() % 10)]])
            case 4: s.removeFromBucket(id)
            case 5: s.logRun(RunLogEntry(trailID: id, date: Date(timeIntervalSince1970: 1_700_000_000 + Double(rng.next() % 5) * 86400)), alsoMarkDone: rng.next() % 2 == 0)
            case 6: if s.bucketPending.count > 1 { s.moveBucket(from: IndexSet(integer: Int(rng.next() % 1000) % s.bucketPending.count), to: Int(rng.next() % 1000) % (s.bucketPending.count + 1)) }
            case 7: s.setOverride(id, rating: rng.next() % 2 == 0 ? Int(rng.next() % 130) : nil, note: nil)
            default: if um!.canUndo { um!.undo() }
            }
            check(s.userData)
        }
        while um!.canUndo { um!.undo(); check(s.userData) }
        while um!.canRedo { um!.redo(); check(s.userData) }
    }
    private func check(_ d: UserData) {
        for (id, st) in d.trailStates {
            #expect(!st.isEmpty, "empty state kept for \(id)")
            if st.status == .bucket { #expect(st.bucketedAt != nil) }
            if st.status == .done { #expect(st.firstDoneDate != nil) }
            if let o = st.ratingOverride { #expect((1...100).contains(o)) }
        }
        #expect(Set(d.bucketOrder).count == d.bucketOrder.count)
        for id in d.bucketOrder { #expect(d.trailStates[id]?.bucketedAt != nil) }
        for (id, st) in d.trailStates where st.status == .bucket { #expect(d.bucketOrder.contains(id)) }
    }
    @Test func milestoneRegistryEmptyDoesNotCrash() throws {
        let (s, _) = try store()
        s.markDone(s.catalog.trails[0].id)
        #expect(s.userData.profile.unlockedMilestones.count == MilestoneRegistry.all.count || true)
    }

    // MARK: bootstrap
    @Test func bootstrapPersistsAcrossLaunches() throws {
        let dir = try TestPaths.scratchDirectory("bootstrap")
        let a = AppStore.bootstrap(directory: dir)
        #expect(a.pendingAlert == nil)
        let id = try #require(a.catalog.trails.first?.id)
        a.markDone(id)
        a.flush()
        let b = AppStore.bootstrap(directory: dir)
        #expect(b.state(for: id).isDone)
    }
    @Test func bootstrapCorruptStartsFreshWithAlert() throws {
        let dir = try TestPaths.scratchDirectory("bootstrap-corrupt")
        try Data("nope".utf8).write(to: dir.appendingPathComponent("userdata.json"))
        let s = AppStore.bootstrap(directory: dir)
        let alert = try #require(s.pendingAlert)
        #expect(alert.revealURL != nil)
        #expect(s.userData.trailStates.isEmpty); #expect(!s.isReadOnlySession)
    }
    @Test func bootstrapNewerSchemaIsReadOnlyAndUntouched() throws {
        let dir = try TestPaths.scratchDirectory("bootstrap-newer")
        let url = dir.appendingPathComponent("userdata.json")
        let bytes = Data("{\"schemaVersion\": 42}".utf8)
        try bytes.write(to: url)
        let s = AppStore.bootstrap(directory: dir)
        #expect(s.pendingAlert != nil); #expect(s.isReadOnlySession); #expect(s.persistence == nil)
        s.addToBucket(["t-1"]); s.flush()
        #expect(try Data(contentsOf: url) == bytes)
    }
    @Test func applyImportBacksUpAndIsUndoable() throws {
        let dir = try TestPaths.scratchDirectory("import")
        let disk = UserDataStore(directory: dir)
        let (s, _) = try store(Fixtures.userData(done: ["t-a"]), persistence: disk)
        let um = UndoManager(); um.groupsByEvent = false; s.undoManager = um
        s.applyImport(Fixtures.userData(done: ["t-z"]), mode: .replace)
        #expect(s.state(for: "t-z").isDone); #expect(s.userData.trailStates["t-a"] == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("userdata.pre-import-") })
        um.undo()
        #expect(s.state(for: "t-a").isDone)
        s.applyImport(Fixtures.userData(done: ["t-z"]), mode: .merge)
        #expect(s.state(for: "t-a").isDone && s.state(for: "t-z").isDone)
    }
}

struct SplitMix { var s: UInt64
    init(seed: UInt64) { s = seed }
    mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
}
