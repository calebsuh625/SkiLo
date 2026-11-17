import Testing
import Foundation
@testable import SkiLo

@Suite("Elo math")
struct EloMathTests {
    @Test func eloIsOnTheSkillScale() {
        #expect(Elo.trailElo(rating: 1) == 1)
        #expect(Elo.trailElo(rating: 100) == 100)
        #expect(Elo.trailElo(rating: 500) == 100)      // clamped
        #expect(Elo.startElo(selfAssessed: 30) == 30)  // "est. 30" from onboarding is the starting Elo
    }
    @Test func evenMatchWinIsHalfK() {
        let d = Elo.delta(player: 50, trailRating: 50, score: 1, priorRunsOnTrail: 0)
        #expect(abs(d - Elo.k / 2) < 1e-9)
    }
    @Test func harderTrailsPayMoreAndEasyOnesAlmostNothing() {
        let hard = Elo.delta(player: 50, trailRating: 80, score: 1, priorRunsOnTrail: 0)
        let easy = Elo.delta(player: 50, trailRating: 10, score: 1, priorRunsOnTrail: 0)
        #expect(hard > 3); #expect(easy < 0.2); #expect(easy > 0)
    }
    @Test func eloStaysWithinOneToHundred() {
        let up = (0..<500).map { EloEvent(trailID: "t\($0)", date: Date(timeIntervalSince1970: Double($0)), score: 1, source: .markDone) }
        #expect(Elo.current(start: 99, events: up, ratings: Dictionary(uniqueKeysWithValues: up.map { ($0.trailID, 100) })) <= 100)
        let down = up.map { var e = $0; e.score = 0; return e }
        #expect(Elo.current(start: 2, events: down, ratings: Dictionary(uniqueKeysWithValues: down.map { ($0.trailID, 1) })) >= 1)
    }
    @Test func formatting() {
        #expect(Elo.format(30) == "30.0")
        #expect(Elo.formatDelta(0.84) == "+0.8")
        #expect(Elo.formatDelta(-1.25) == "−1.3" || Elo.formatDelta(-1.25) == "−1.2")
        #expect(Elo.formatDelta(0.02) == nil)
    }
    @Test func skillHistoryIsEloPerDay() {
        var profile = UserProfile(); profile.selfAssessedStart = 30
        profile.startDate = Date(timeIntervalSince1970: 1_699_000_000)
        let d1 = Date(timeIntervalSince1970: 1_700_000_000), d2 = d1.addingTimeInterval(2 * 86400)
        let events = [EloEvent(trailID: "a", date: d1, score: 1, source: .markDone),
                      EloEvent(trailID: "b", date: d1.addingTimeInterval(600), score: 1, source: .markDone),
                      EloEvent(trailID: "a", date: d2, score: 1, source: .logRun)]
        let ratings = ["a": 45, "b": 50]
        let h = Elo.skillHistory(profile: profile, events: events, ratings: ratings)
        #expect(h.count == 3)                               // start + two ski days
        #expect(h[0].value == 30); #expect(h[0].runCount == 0)
        #expect(h[1].runCount == 2); #expect(h[2].runCount == 3)
        #expect(h.map(\.date) == h.map(\.date).sorted())     // plots left to right
        #expect(h[1].date == d1.addingTimeInterval(600))     // that day's last run
        #expect(abs(h[2].value - Elo.current(start: 30, events: events, ratings: ratings)) < 1e-9)
    }
    @Test func repeatsCountForLess() {
        let me = 50.0
        let first = Elo.delta(player: me, trailRating: 60, score: 1, priorRunsOnTrail: 0)
        let fourth = Elo.delta(player: me, trailRating: 60, score: 1, priorRunsOnTrail: 3)
        #expect(abs(fourth - first / 2) < 1e-9)
    }
    @Test func strugglingLosesPoints() {
        #expect(Elo.score(confidence: 1) == 0); #expect(Elo.score(confidence: 2) == 0.5); #expect(Elo.score(confidence: 4) == 1)
        #expect(Elo.delta(player: 50, trailRating: 30, score: 0, priorRunsOnTrail: 0) < 0)
    }
    @Test func historyReplaysInDateOrder() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [EloEvent(trailID: "b", date: t0.addingTimeInterval(60), score: 1, source: .markDone),
                      EloEvent(trailID: "a", date: t0, score: 1, source: .markDone),
                      EloEvent(trailID: "missing", date: t0, score: 1, source: .markDone)]
        let h = Elo.history(start: 30, events: events, ratings: ["a": 40, "b": 40])
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

    @Test func startsAtSelfAssessedSkillAsEstimate() throws {
        let s = try store()                               // selfAssessedStart = 40
        #expect(s.elo == 40); #expect(s.eloIsProvisional); #expect(s.skill.value == 40)
        s.markDone(hardTrail(s))
        #expect(s.skill.value == s.elo)                   // the skill estimate *is* the Elo
        #expect(s.userData.profile.skillHistory.last?.value == s.elo)
        s.markDone(s.catalog.trails[0].id); s.markDone(s.catalog.trails[1].id)
        #expect(!s.eloIsProvisional)                      // "est." drops after 3 runs
    }
    @Test func loggingAnyRunUpdatesElo() throws {
        let s = try store()
        let id = hardTrail(s)
        for confidence in 1...5 {
            let before = s.elo
            s.logRun(RunLogEntry(trailID: id, date: .now, confidence: confidence), alsoMarkDone: false)
            #expect(s.elo != before, "confidence \(confidence)")
            #expect(s.skill.value == s.elo)
        }
    }
    @Test func markDoneRaisesEloOncePerDay() throws {
        let s = try store()
        let start = s.elo
        let id = hardTrail(s)
        let preview = s.eloPreview(for: id)
        s.markDone(id)
        #expect(s.userData.eloEvents.count == 1)
        #expect(abs(s.elo - (start + preview)) < 1e-9)
        #expect(abs((s.lastEloDelta ?? 0) - preview) < 1e-9)
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
    /// Every UI path that completes a run must add exactly one Elo game and move the Elo.
    @Test func everyCompletionPathUpdatesElo() throws {
        let s = try store()
        let trails = s.catalog.trails.sorted { $0.rating.total > $1.rating.total }.map(\.id)   // hardest first: always a gain
        func check(_ label: String, games: Int = 1, _ action: () -> Void) {
            let (eloBefore, before) = (s.elo, s.userData.eloEvents.count)
            action()
            #expect(s.userData.eloEvents.count == before + games, "\(label): games")
            #expect(s.elo > eloBefore, "\(label): Elo should rise")
        }
        check("inspector / ⌘D / bucket Done button") { s.markDone(trails[0]) }
        check("toggleDone (⌘D menu)") { s.toggleDone(trails[1]) }
        check("Trails list bulk Mark Done", games: 2) { s.markDone([trails[2], trails[3]], backfilled: false) }
        s.addToBucket([trails[4]])
        check("bucket list cross-off") { s.markDone(trails[4]) }
        check("Log Run… + mark done") { s.logRun(RunLogEntry(trailID: trails[5], date: .now, confidence: 4), alsoMarkDone: true) }
        check("Log Run… on a done trail") { s.logRun(RunLogEntry(trailID: trails[0], date: .now, confidence: 4), alsoMarkDone: false) }
        check("Ran It Again") { s.recordAnotherRun(trails[1]) }
        check("Ran It Again, same day again") { s.recordAnotherRun(trails[1]) }
        check("Ran It Again on a not-done trail") { s.recordAnotherRun(trails[6]) }
    }
    @Test func ranItAgainCountsRunsAndUndoes() throws {
        let s = try store()
        let um = UndoManager(); um.groupsByEvent = false; s.undoManager = um
        let id = hardTrail(s)
        s.markDone(id)
        let afterFirst = s.elo
        s.recordAnotherRun(id); s.recordAnotherRun(id)
        #expect(s.state(for: id).timesSkied == 3)
        #expect(s.userData.eloEvents.count == 3)
        let afterThird = s.elo
        #expect(afterThird > afterFirst)
        um.undo()
        #expect(s.userData.eloEvents.count == 2); #expect(s.elo < afterThird)
        s.markNotDone(id)                                  // un-doing the trail removes its marked runs
        #expect(s.userData.eloEvents.isEmpty)
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
    init() { PasswordHash.defaultIterations = 1_000 }      // keep tests fast

    @Test func createValidatesUsernameAndPassword() throws {
        let m = AccountManager(root: try TestPaths.scratchDirectory("acct-names"))
        #expect(m.store == nil)
        try m.createAccount(username: "  caleb_s  ", password: "powderday", remember: false)
        #expect(m.current?.username == "caleb_s")
        #expect(m.store != nil)
        #expect(throws: AccountError.usernameTaken("CALEB_S")) { try m.createAccount(username: "CALEB_S", password: "powderday", remember: false) }
        #expect(throws: AccountError.invalidUsername) { try m.createAccount(username: "ab", password: "powderday", remember: false) }
        #expect(throws: AccountError.invalidUsername) { try m.createAccount(username: "has space", password: "powderday", remember: false) }
        #expect(throws: AccountError.weakPassword) { try m.createAccount(username: "newbie", password: "short", remember: false) }
    }
    @Test func passwordIsHashedAndChecked() throws {
        let root = try TestPaths.scratchDirectory("acct-password")
        let m = AccountManager(root: root)
        try m.createAccount(username: "ava", password: "correct horse", remember: false)
        let file = try String(contentsOf: m.indexURL, encoding: .utf8)
        #expect(!file.contains("correct horse"))
        m.signOut()
        #expect(throws: AccountError.wrongCredentials) { try m.signIn(username: "ava", password: "wrong pass", remember: false) }
        #expect(throws: AccountError.wrongCredentials) { try m.signIn(username: "nobody", password: "correct horse", remember: false) }
        #expect(m.store == nil)
        try m.signIn(username: "AVA", password: "correct horse", remember: false)    // usernames are case-insensitive
        #expect(m.current?.username == "ava")
    }
    @Test func rememberMeControlsAutoSignIn() throws {
        let root = try TestPaths.scratchDirectory("acct-remember")
        let m = AccountManager(root: root)
        try m.createAccount(username: "kept", password: "password1", remember: true)
        #expect(m.isRemembered)
        #expect(AccountManager(root: root).current?.username == "kept")      // next launch: still signed in
        try m.createAccount(username: "guest", password: "password1", remember: false)
        #expect(AccountManager(root: root).current == nil)                    // not remembered: sign-in screen
        try m.signIn(username: "kept", password: "password1", remember: true)
        m.signOut()                                                           // sign out forgets it
        #expect(AccountManager(root: root).current == nil)
    }
    @Test func changePassword() throws {
        let m = AccountManager(root: try TestPaths.scratchDirectory("acct-change"))
        let a = try m.createAccount(username: "skier", password: "password1", remember: false)
        #expect(throws: AccountError.wrongCredentials) { try m.changePassword(a.id, current: "nope-nope", new: "password2") }
        try m.changePassword(a.id, current: "password1", new: "password2")
        m.signOut()
        #expect(throws: AccountError.wrongCredentials) { try m.signIn(username: "skier", password: "password1", remember: false) }
        try m.signIn(username: "skier", password: "password2", remember: false)
    }
    @Test func accountsKeepSeparateDataAndElo() throws {
        let root = try TestPaths.scratchDirectory("acct-isolation")
        let m = AccountManager(root: root)
        try m.createAccount(username: "alpha", password: "password1", remember: false)
        let store = try #require(m.store)
        let id = store.catalog.trails.max { $0.rating.total < $1.rating.total }!.id
        store.markDone(id)
        let aElo = store.elo
        try m.createAccount(username: "bravo", password: "password1", remember: false)
        #expect(m.store?.doneCount == 0)
        #expect(m.store?.elo != aElo)
        try m.signIn(username: "alpha", password: "password1", remember: false)
        #expect(m.store?.elo == aElo)
        #expect(m.store?.state(for: id).isDone == true)
    }
    @Test func deleteMovesDataToTrash() throws {
        let m = AccountManager(root: try TestPaths.scratchDirectory("acct-delete"))
        let a = try m.createAccount(username: "temp", password: "password1", remember: true)
        try m.deleteAccount(a.id)
        #expect(m.store == nil); #expect(m.accounts.isEmpty); #expect(m.index.rememberedID == nil)
        #expect(!FileManager.default.fileExists(atPath: m.directory(for: a.id).path))
    }
}
