import Testing
import Foundation
@testable import HeavenlyTracker

/// Whole-second dates so ISO-8601 round trips compare equal.
private func t(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + s) }

private func sample() -> UserData {
    var d = UserData.fresh()
    d.createdAt = t(0); d.updatedAt = t(100)
    d.profile.startDate = t(0); d.profile.selfAssessedStart = 42; d.profile.onboardingDone = true
    var a = UserTrailState(); a.status = .done; a.bucketedAt = t(5); a.firstDoneDate = t(50); a.lastDoneDate = t(60); a.timesSkied = 2; a.notes = "fun"
    var b = UserTrailState(); b.status = .bucket; b.bucketedAt = t(6); b.ratingOverride = 70; b.ratingOverrideNote = "icy"
    d.trailStates = ["t-a": a, "t-b": b]
    d.bucketOrder = ["t-b", "t-a"]
    d.runLog = [RunLogEntry(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, trailID: "t-a", date: t(50), conditions: .powder, confidence: 4, notes: "n", isFirstTime: true)]
    d.skiDays = ["2023-11-14": SkiDayMeta(title: "Opening", conditions: .groomed, notes: "x")]
    d.profile.skillHistory = [SkillPoint(date: t(50), value: 44, low: 38, high: 50, runCount: 1)]
    d.profile.unlockedMilestones = ["first.green": t(51)]
    return d
}

@Suite("Persistence")
struct PersistenceTests {
    @Test func encodeDecodeRoundTrip() throws {
        let d = sample()
        #expect(try UserDataStore.decode(UserDataStore.encode(d)) == d)
    }
    @Test func saveLoadRoundTrip() throws {
        let dir = try TestPaths.scratchDirectory("roundtrip")
        let store = UserDataStore(directory: dir)
        guard case .fresh = store.load() else { Issue.record("expected fresh"); return }
        store.scheduleSave(sample()); store.flush()
        guard case .loaded(let d) = UserDataStore(directory: dir).load() else { Issue.record("expected loaded"); return }
        #expect(d == sample())
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("userdata.json.tmp").path))
    }
    @Test func emptyStatesArePrunedOnSave() throws {
        let dir = try TestPaths.scratchDirectory("prune")
        var d = sample(); d.trailStates["t-empty"] = UserTrailState()
        let store = UserDataStore(directory: dir); try store.write(d)
        guard case .loaded(let back) = store.load() else { Issue.record("load"); return }
        #expect(back.trailStates["t-empty"] == nil)
        #expect(back.trailStates.count == 2)
    }
    @Test func backupRotation() throws {
        let dir = try TestPaths.scratchDirectory("backup")
        let store = UserDataStore(directory: dir)
        var v1 = sample(); v1.profile.selfAssessedStart = 11
        var v2 = sample(); v2.profile.selfAssessedStart = 22
        try store.write(v1)
        #expect(!FileManager.default.fileExists(atPath: store.backupURL.path))
        try store.write(v2)
        #expect(try UserDataStore.decode(Data(contentsOf: store.backupURL)).profile.selfAssessedStart == 11)
        #expect(try UserDataStore.decode(Data(contentsOf: store.fileURL)).profile.selfAssessedStart == 22)
    }
    @Test func corruptFileIsMovedAndReported() throws {
        let dir = try TestPaths.scratchDirectory("corrupt")
        let store = UserDataStore(directory: dir)
        try Data("{ not json".utf8).write(to: store.fileURL)
        guard case .corrupt(let moved, _) = store.load() else { Issue.record("expected corrupt"); return }
        let m = try #require(moved)
        #expect(m.lastPathComponent.hasPrefix("userdata.corrupt-"))
        #expect(FileManager.default.fileExists(atPath: m.path))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }
    @Test func corruptFileFallsBackToBackup() throws {
        let dir = try TestPaths.scratchDirectory("recover")
        let store = UserDataStore(directory: dir)
        try store.write(sample()); try store.write(sample())          // creates a backup
        try Data("garbage".utf8).write(to: store.fileURL)
        guard case .recoveredFromBackup(let d) = store.load() else { Issue.record("expected recovered"); return }
        #expect(d == sample())
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("userdata.corrupt-") })
    }
    @Test func corruptMainDoesNotOverwriteGoodBackup() throws {
        let dir = try TestPaths.scratchDirectory("keepbackup")
        let store = UserDataStore(directory: dir)
        try store.write(sample()); try store.write(sample())
        try Data("garbage".utf8).write(to: store.fileURL)
        try store.write(UserData.fresh())              // main unreadable → must not replace the backup with garbage
        #expect(try UserDataStore.decode(Data(contentsOf: store.backupURL)) == sample())
    }
    @Test func newerSchemaIsRefusedAndFileUntouched() throws {
        let dir = try TestPaths.scratchDirectory("newer")
        let store = UserDataStore(directory: dir)
        let bytes = Data("{\"schemaVersion\": 99, \"futureField\": 1}".utf8)
        try bytes.write(to: store.fileURL)
        guard case .newerSchema(let n) = store.load() else { Issue.record("expected newerSchema"); return }
        #expect(n == 99)
        #expect(try Data(contentsOf: store.fileURL) == bytes)
    }
    @Test func missingMainWithBackupRecovers() throws {
        let dir = try TestPaths.scratchDirectory("missingmain")
        let store = UserDataStore(directory: dir)
        try store.write(sample()); try store.write(sample())
        try FileManager.default.removeItem(at: store.fileURL)
        guard case .recoveredFromBackup = store.load() else { Issue.record("expected recovered"); return }
    }
    @Test func debounceCoalescesWrites() async throws {
        let dir = try TestPaths.scratchDirectory("debounce")
        let store = UserDataStore(directory: dir)
        store.debounce = 0.3
        var d = sample()
        for i in 1...3 { d.profile.selfAssessedStart = i; store.scheduleSave(d); try await Task.sleep(nanoseconds: 30_000_000) }
        #expect(store.writeCount == 0)
        #expect(store.hasPendingSave)
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(store.writeCount == 1)
        #expect(!store.hasPendingSave)
        #expect(try UserDataStore.decode(Data(contentsOf: store.fileURL)).profile.selfAssessedStart == 3)
    }
    @Test func flushWritesSynchronouslyAndCancelsDebounce() async throws {
        let dir = try TestPaths.scratchDirectory("flush")
        let store = UserDataStore(directory: dir)
        store.debounce = 0.2
        store.scheduleSave(sample())
        store.flush()
        #expect(store.writeCount == 1)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(store.writeCount == 1)           // the cancelled debounce did not write again
        store.flush()                            // nothing pending → no-op
        #expect(store.writeCount == 1)
    }

    // MARK: migrations
    @Test func v1DocumentLoadsThroughMigrations() throws {
        let json = """
        {"schemaVersion":1,"appVersion":"0.1.0","createdAt":"2023-11-14T22:13:20Z","updatedAt":"2023-11-14T22:13:20Z",
         "profile":{"selfAssessedStart":55,"startDate":"2023-11-14T22:13:20Z"},
         "trailStates":{"t-x":{"status":"done","firstDoneDate":"2023-11-14T22:13:20Z"}},"bucketOrder":[],"runLog":[],"skiDays":{}}
        """
        let d = try UserDataStore.decode(Data(json.utf8))
        #expect(d.profile.selfAssessedStart == 55)
        #expect(d.state(for: "t-x").isDone)
        #expect(d.schemaVersion == 1)
    }
    @Test func documentWithoutSchemaVersionIsTreatedAsV1() throws {
        let d = try UserDataStore.decode(Data("{\"trailStates\":{}}".utf8))
        #expect(d.schemaVersion == 1)
    }
    @Test func migrationChainRunsInOrder() throws {
        let steps: [Int: Migrations.Step] = [
            1: { var j = $0; j["trace"] = ((j["trace"] as? String) ?? "") + "1>2;"; return j },
            2: { var j = $0; j["trace"] = ((j["trace"] as? String) ?? "") + "2>3;"; return j },
        ]
        let out = try Migrations.run(json: ["schemaVersion": 1], from: 1, to: 3, steps: steps)
        #expect(out["trace"] as? String == "1>2;2>3;")
        #expect(out["schemaVersion"] as? Int == 3)
        let mid = try Migrations.run(json: ["schemaVersion": 2], from: 2, to: 3, steps: steps)
        #expect(mid["trace"] as? String == "2>3;")
    }
    @Test func migrationRejectsNewerVersion() {
        #expect(throws: MigrationError.newerSchema(5)) { try Migrations.run(json: [:], from: 5) }
        #expect(throws: MigrationError.newerSchema(2)) { try Migrations.run(json: [:], from: 2, to: 1, steps: [:]) }
    }

    // MARK: export / import
    @Test func exportAddsExportedAtAndImportReadsBackEqual() throws {
        let dir = try TestPaths.scratchDirectory("export")
        let url = dir.appendingPathComponent("export.json")
        let d = sample()
        try ExportImport.export(d, to: url)
        let obj = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let stamp = try #require(obj["exportedAt"] as? String)
        #expect(ISO8601DateFormatter().date(from: stamp) != nil)
        let (back, summary) = try ExportImport.read(from: url)
        #expect(back == d)
        #expect(summary == ImportSummary(doneCount: 1, runCount: 1, bucketCount: 1, earliestDate: t(50)))
    }
    @Test func importOfNewerExportFails() throws {
        let url = try TestPaths.scratchDirectory("newerexport").appendingPathComponent("x.json")
        try Data("{\"schemaVersion\": 7}".utf8).write(to: url)
        #expect(throws: MigrationError.newerSchema(7)) { try ExportImport.read(from: url) }
    }
    @Test func mergeFollowsUXRules() {
        var local = UserData.fresh(); var imp = UserData.fresh()
        var l = UserTrailState(); l.status = .bucket; l.bucketedAt = t(10); l.notes = "mine"
        var i = UserTrailState(); i.status = .done; i.bucketedAt = t(5); i.firstDoneDate = t(20); i.lastDoneDate = t(30); i.notes = "theirs"; i.ratingOverride = 61
        local.trailStates = ["t-a": l, "t-only-local": l]; local.bucketOrder = ["t-a", "t-only-local"]
        imp.trailStates = ["t-a": i, "t-new": i]; imp.bucketOrder = ["t-new", "t-a"]
        let shared = RunLogEntry(id: UUID(), trailID: "t-a", date: t(20))
        local.runLog = [shared]; imp.runLog = [shared, RunLogEntry(id: UUID(), trailID: "t-a", date: t(30))]
        local.profile.unlockedMilestones = ["m": t(90)]; imp.profile.unlockedMilestones = ["m": t(40), "n": t(41)]
        let m = ExportImport.merge(local: local, imported: imp)
        let a = m.state(for: "t-a")
        #expect(a.status == .done); #expect(a.bucketedAt == t(5)); #expect(a.firstDoneDate == t(20)); #expect(a.lastDoneDate == t(30))
        #expect(a.timesSkied == 2); #expect(a.ratingOverride == 61); #expect(a.notes == "mine\n---\ntheirs")
        #expect(m.runLog.count == 2)
        #expect(m.bucketOrder == ["t-a", "t-only-local", "t-new"])
        #expect(m.profile.unlockedMilestones == ["m": t(40), "n": t(41)])
        #expect(m.state(for: "t-new") == i)
    }
}
