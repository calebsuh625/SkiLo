import Testing
import Foundation
@testable import HeavenlyTracker

@Suite("Elo math")
struct EloMathTests {
    @Test func trailEloSpansRatingScale() {
        #expect(Elo.trailElo(rating: 1) == 800)
        #expect(Elo.trailElo(rating: 100) == 1988)
        #expect(Elo.trailElo(rating: 500) == 1988)     // clamped
    }
    @Test func evenMatchWinIsHalfK() {
        let d = Elo.delta(player: Elo.trailElo(rating: 50), trailRating: 50, score: 1, priorRunsOnTrail: 0)
        #expect(abs(d - 16) < 1e-9)
    }
    @Test func harderTrailsPayMoreAndEasyOnesAlmostNothing() {
        let me = Elo.trailElo(rating: 50)
        let hard = Elo.delta(player: me, trailRating: 80, score: 1, priorRunsOnTrail: 0)
        let easy = Elo.delta(player: me, trailRating: 10, score: 1, priorRunsOnTrail: 0)
        #expect(hard > 25); #expect(easy < 2); #expect(easy > 0)
    }
    @Test func repeatsCountForLess() {
        let me = Elo.trailElo(rating: 50)
        let first = Elo.delta(player: me, trailRating: 60, score: 1, priorRunsOnTrail: 0)
        let fourth = Elo.delta(player: me, trailRating: 60, score: 1, priorRunsOnTrail: 3)
        #expect(abs(fourth - first / 2) < 1e-9)
    }
    @Test func strugglingLosesPoints() {
        #expect(Elo.score(confidence: 1) == 0); #expect(Elo.score(confidence: 2) == 0.5); #expect(Elo.score(confidence: 4) == 1)
        #expect(Elo.delta(player: 1200, trailRating: 30, score: 0, priorRunsOnTrail: 0) < 0)
    }
    @Test func historyReplaysInDateOrder() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [EloEvent(trailID: "b", date: t0.addingTimeInterval(60), score: 1, source: .markDone),
                      EloEvent(trailID: "a", date: t0, score: 1, source: .markDone),
                      EloEvent(trailID: "missing", date: t0, score: 1, source: .markDone)]
        let h = Elo.history(start: 1000, events: events, ratings: ["a": 40, "b": 40])
        #expect(h.map(\.trailID) == ["a", "b"])
        #expect(h[1].elo > h[0].elo)
    }
}

@Suite("Elo in the store")
@MainActor
struct EloStoreTests {
    private func store() throws -> AppStore {
        var ud = Fixtures.userData(); ud.profile.selfAssessedStart = 40
        return AppStore(catalog: try Fixtures.bundledCatalog(), userData: ud, persistence: nil)
    }
    private func hardTrail(_ s: AppStore) -> Trail.ID { s.catalog.trails.max { $0.rating.total < $1.rating.total }!.id }
    private func easyTrail(_ s: AppStore) -> Trail.ID { s.catalog.trails.min { $0.rating.total < $1.rating.total }!.id }

    @Test func markDoneRaisesEloOncePerDay() throws {
        let s = try store()
        let start = s.elo
        let id = hardTrail(s)
        let preview = s.eloPreview(for: id)
        s.markDone(id)
        #expect(s.userData.eloEvents.count == 1)
        #expect(s.elo == start + preview)
        #expect(s.lastEloDelta == preview)
        s.markDone(id)                                    // same day: no second game
        #expect(s.userData.eloEvents.count == 1)
    }
    @Test func markNotDoneAndUndoRestoreElo() throws {
        let s = try store()
        let um = UndoManager(); um.groupsByEvent = false; s.undoManager = um
        let start = s.elo
        let id = hardTrail(s)
        s.markDone(id)
        let after = s.elo
        #expect(after > start)
        s.markNotDone(id)
        #expect(s.elo == start); #expect(s.userData.eloEvents.isEmpty)
        um.undo()
        #expect(s.elo == after)
        um.undo()
        #expect(s.elo == start)
    }
    @Test func backfillDoesNotCount() throws {
        let s = try store()
        let start = s.elo
        s.completeOnboarding(selfAssessed: 40, backfill: [.green, .blue])
        #expect(s.doneCount > 0)
        #expect(s.userData.eloEvents.isEmpty)
        #expect(s.elo == start)
    }
    @Test func roughRunOnEasyTrailLosesAndDeleteRestores() throws {
        let s = try store()
        let start = s.elo
        let entry = RunLogEntry(trailID: easyTrail(s), date: .now, confidence: 1)
        s.logRun(entry, alsoMarkDone: true)
        #expect(s.userData.eloEvents.count == 1)          // log + mark done is one game, not two
        #expect(s.elo < start)
        s.deleteRun(entry.id)
        #expect(s.userData.eloEvents.isEmpty)
        #expect(s.elo == start)
    }
    @Test func editingRunConfidenceRescores() throws {
        let s = try store()
        var entry = RunLogEntry(trailID: hardTrail(s), date: .now, confidence: 1)
        s.logRun(entry, alsoMarkDone: false)
        let rough = s.elo
        entry.confidence = 5
        s.updateRun(entry)
        #expect(s.elo > rough)
    }
    @Test func eloEventsSurviveEncodeDecode() throws {
        let s = try store()
        s.markDone(hardTrail(s))
        let back = try UserDataStore.decode(UserDataStore.encode(s.userData))
        // ISO-8601 drops sub-second precision, so compare everything but the exact instant.
        #expect(back.eloEvents.map(\.id) == s.userData.eloEvents.map(\.id))
        #expect(back.eloEvents.map(\.score) == s.userData.eloEvents.map(\.score))
        #expect(abs(back.eloEvents[0].date.timeIntervalSince(s.userData.eloEvents[0].date)) < 1)
    }
}

@Suite("Accounts")
@MainActor
struct AccountTests {
    @Test func createValidatesNames() throws {
        let m = AccountManager(root: try TestPaths.scratchDirectory("acct-names"))
        #expect(m.store == nil)
        try m.createAccount(name: "  Ava  ")
        #expect(m.current?.name == "Ava")
        #expect(m.store != nil)
        #expect(throws: AccountError.duplicateName("ava")) { try m.createAccount(name: "ava") }
        #expect(throws: AccountError.emptyName) { try m.createAccount(name: "   ") }
    }
    @Test func accountsKeepSeparateDataAndElo() throws {
        let root = try TestPaths.scratchDirectory("acct-isolation")
        let m = AccountManager(root: root)
        let a = try m.createAccount(name: "A")
        let store = try #require(m.store)
        let id = store.catalog.trails.max { $0.rating.total < $1.rating.total }!.id
        store.markDone(id)
        let aElo = store.elo
        let b = try m.createAccount(name: "B")
        #expect(m.current?.id == b.id)
        #expect(m.store?.doneCount == 0)
        #expect(m.store?.elo != aElo)
        m.signIn(a.id)
        #expect(m.store?.elo == aElo)
        #expect(m.store?.state(for: id).isDone == true)
        // Index and current account persist across launches.
        let reopened = AccountManager(root: root)
        #expect(reopened.accounts.map(\.name) == ["A", "B"])
        #expect(reopened.current?.id == a.id)
        #expect(reopened.store?.elo == aElo)
    }
    @Test func signOutAndDelete() throws {
        let m = AccountManager(root: try TestPaths.scratchDirectory("acct-delete"))
        let a = try m.createAccount(name: "Temp")
        m.signOut()
        #expect(m.store == nil); #expect(m.current == nil)
        try m.deleteAccount(a.id)
        #expect(m.accounts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: m.directory(for: a.id).path))
    }
    @Test func legacyDataMovesIntoFirstAccount() throws {
        let root = try TestPaths.scratchDirectory("acct-legacy")
        var ud = UserData.fresh(); ud.profile.onboardingDone = true
        ud.trailStates["t-legacy"] = { var s = UserTrailState(); s.notes = "kept"; return s }()
        try UserDataStore(directory: root).write(ud)
        let m = AccountManager(root: root)
        #expect(m.accounts.count == 1)
        let acct = try #require(m.current)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("userdata.json").path))
        #expect(FileManager.default.fileExists(atPath: m.directory(for: acct.id).appendingPathComponent("userdata.json").path))
        #expect(m.store?.userData.trailStates["t-legacy"]?.notes == "kept")
    }
}
