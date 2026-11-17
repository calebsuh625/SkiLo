import Foundation
import Testing
@testable import SkiLo

@Suite struct ProgressionTests {
    let engine = DefaultProgressionEngine()
    let cal = Calendar.current
    let t0 = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    func day(_ n: Int, hour: Int = 10) -> Date {
        cal.date(byAdding: .hour, value: hour, to: cal.date(byAdding: .day, value: n, to: t0)!)!
    }
    func profile(seed: Int = 30) -> UserProfile {
        var p = UserProfile(); p.selfAssessedStart = seed; p.startDate = day(-1); return p
    }
    func run(_ id: String, _ d: Int, _ c: Conditions = .groomed, conf: Int = 3) -> RunLogEntry {
        RunLogEntry(trailID: id, date: day(d), conditions: c, confidence: conf)
    }
    func skill(_ v: Double, basis: Int = 7) -> SkillEstimate { SkillEstimate(value: v, low: v - 3, high: v + 3, basisRuns: basis) }

    @Test func noRunsIsSeed() {
        let h = engine.skillHistory(profile: profile(seed: 42), log: [], ratings: [:])
        #expect(h.count == 1 && h[0].value == 42 && h[0].runCount == 0 && h[0].low == 32 && h[0].high == 52)
        #expect(engine.currentSkill(history: h, profile: profile(seed: 42)).value == 42)
        #expect(engine.currentSkill(history: [], profile: profile(seed: 42)).isProvisional)
    }

    @Test func oneRunIsMaxMinusFive() {
        let h = engine.skillHistory(profile: profile(seed: 20), log: [run("a", 0)], ratings: ["a": 60])
        #expect(h.count == 2)
        #expect(h[1].value == 55 && h[1].runCount == 1 && h[1].low == 46 && h[1].high == 64)  // ±(10−1)
    }

    @Test func threeRunsUseWeightedEightiethPercentile() {
        // m = 40, 50, 60 same day, equal weights: total 3, target 2.4 -> third value (60).
        let log = [run("a", 0), run("b", 0), run("c", 0)]
        let h = engine.skillHistory(profile: profile(seed: 10), log: log, ratings: ["a": 40, "b": 50, "c": 60])
        #expect(h.last!.value == 60 && h.last!.runCount == 3 && h.last!.low == 53)
        // Five equal-weight values 10..50: target 4.0 -> fourth value (40).
        let items = (1...5).map { (value: Double($0 * 10), weight: 1.0) }
        #expect(DefaultProgressionEngine.weightedPercentile(items, p: 0.8) == 40)
    }

    @Test func conditionsAndConfidenceShiftMastery() {
        // rating 50 firm (x1.15) = 57.5, confidence 5 -> +8 = 65.5; single run -> 60.5
        let h = engine.skillHistory(profile: profile(seed: 10), log: [run("a", 0, .firm, conf: 5)], ratings: ["a": 50])
        #expect(abs(h.last!.value - 60.5) < 1e-9)
        // clamp to 100 before confidence
        #expect(DefaultProgressionEngine.mastery(rating: 95, entry: run("a", 0, .firm, conf: 3)) == 100)
    }

    @Test func recencyDecayWeights() {
        #expect(DefaultProgressionEngine.weight(ageDays: 0) == 1)
        #expect(abs(DefaultProgressionEngine.weight(ageDays: 30) - 0.5) < 1e-12)
        #expect(abs(DefaultProgressionEngine.weight(ageDays: 60) - 0.25) < 1e-12)
        // A 90 run weighted 0.25 vs two 50 runs weighted 1: total 2.25, target 1.8 -> 50 (undecayed would give 90).
        let decayed = DefaultProgressionEngine.weightedPercentile([(90, 0.25), (50, 1), (50, 1)], p: 0.8)
        let flat = DefaultProgressionEngine.weightedPercentile([(90, 1), (50, 1), (50, 1)], p: 0.8)
        #expect(decayed == 50 && flat == 90)
    }

    @Test func oldRunsLeaveTheWindowAndSmoothingFloors() {
        // Day 0: one run on a 80 -> 75. Day 70: one run on a 30 (day-0 run is outside 60 days) -> raw 25,
        // floored to 0.9 * 75 = 67.5.
        let log = [run("hard", 0), run("easy", 70)]
        let h = engine.skillHistory(profile: profile(), log: log, ratings: ["hard": 80, "easy": 30])
        #expect(h[1].value == 75)
        #expect(h[2].runCount == 1)
        #expect(abs(h[2].value - 67.5) < 1e-9)
    }

    @Test func monotonicMoreHardRunsHigherSkill() {
        var ratings: [String: Int] = [:]
        var prev = -1.0
        for hard in 0...6 {
            var log: [RunLogEntry] = []
            for i in 0..<6 {
                let id = "r\(i)"
                ratings[id] = i < hard ? 70 : 30
                log.append(run(id, 0))
            }
            let v = engine.skillHistory(profile: profile(seed: 20), log: log, ratings: ratings).last!.value
            #expect(v >= prev, "hard=\(hard) v=\(v) prev=\(prev)")
            prev = v
        }
        #expect(prev == 70)
    }

    @Test func unknownTrailsIgnoredAndOneSkiDayPerPoint() {
        let log = [run("a", 0), run("a", 0), run("ghost", 1), run("a", 2)]
        let h = engine.skillHistory(profile: profile(), log: log, ratings: ["a": 50])
        #expect(h.count == 3)  // seed + day 0 + day 2 (ghost day ignored)
    }

    @Test func readinessCutPoints() {
        func kind(_ r: Int) -> Readiness.Kind { engine.readiness(rating: r, modifiers: .none, skill: skill(50)).kind }
        #expect(kind(42) == .belowYou); #expect(kind(43) == .ready)
        #expect(kind(57) == .ready);    #expect(kind(58) == .stretch)
        #expect(kind(65) == .stretch);  #expect(kind(66) == .bigStretch)
        let r = engine.readiness(rating: 58, modifiers: .none, skill: skill(58))
        #expect(r.reason == "right at your level (Elo 58)" && r.delta == 0)
    }

    @Test func gateAndHikeRules() {
        var m = CuratedModifiers.none; m.gated = true
        let g = engine.readiness(rating: 55, modifiers: m, skill: skill(55))
        #expect(g.kind == .bigStretch && g.reason == "behind a gate — build to 58 first")
        #expect(engine.readiness(rating: 60, modifiers: m, skill: skill(60)).kind == .ready)
        var h = CuratedModifiers.none; h.hikeTo = true
        let hr = engine.readiness(rating: 62, modifiers: h, skill: skill(62))
        #expect(hr.kind == .bigStretch && hr.reason == "hike-to — build to 65 first")
        #expect(engine.readiness(rating: 66, modifiers: h, skill: skill(66)).kind == .ready)
    }

    // MARK: ordering

    func catalog() throws -> TrailCatalog { try CatalogLoader.loadBundled() }

    @Test func readyForOrderingAndSuggestedNext() throws {
        let base = try catalog().trails[0]
        // Build trails by re-decoding with different id/name.
        func trail(_ id: String, _ name: String) throws -> Trail {
            var o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as! [String: Any]
            o["id"] = id; o["name"] = name
            return try JSONDecoder().decode(Trail.self, from: JSONSerialization.data(withJSONObject: o))
        }
        let ts = [try trail("t-a", "Alpha"), try trail("t-b", "Bravo"), try trail("t-c", "Charlie"), try trail("t-d", "Delta"), try trail("t-e", "Echo")]
        // skill 50: deltas  a:+3 (best), b:+3 (tie, name), c:-5, d:+9 (stretch), e:-20 (below)
        let ratings = ["t-a": 53, "t-b": 53, "t-c": 45, "t-d": 59, "t-e": 30]
        let ready = engine.readyFor(trails: ts, ratings: ratings, states: [:], skill: skill(50), limit: 10)
        #expect(ready == ["t-a", "t-b", "t-c"])
        #expect(engine.readyFor(trails: ts, ratings: ratings, states: [:], skill: skill(50), limit: 1) == ["t-a"])
        var done = UserTrailState(); done.status = .done
        #expect(engine.readyFor(trails: ts, ratings: ratings, states: ["t-a": done], skill: skill(50), limit: 10) == ["t-b", "t-c"])

        var b = UserTrailState(); b.status = .bucket
        let states = ["t-a": b, "t-b": b, "t-c": b, "t-d": b]
        let byID = Dictionary(uniqueKeysWithValues: ts.map { ($0.id, $0) })
        // Lowest non-negative delta among ready: a and b both +3 -> first in bucket order (a); c (-5) loses.
        let s1 = engine.suggestedNext(bucket: ["t-c", "t-b", "t-a", "t-d"], trails: byID, ratings: ratings, states: states, skill: skill(50))
        #expect(s1?.id == "t-b")  // tie keeps bucket order: b appears before a
        let s2 = engine.suggestedNext(bucket: ["t-c", "t-d"], trails: byID, ratings: ratings, states: states, skill: skill(50))
        #expect(s2?.id == "t-c")  // only negative ready
        let s3 = engine.suggestedNext(bucket: ["t-d"], trails: byID, ratings: ratings, states: states, skill: skill(30))
        #expect(s3?.id == "t-d")  // smallest stretch fallback
        #expect(engine.suggestedNext(bucket: [], trails: byID, ratings: ratings, states: states, skill: skill(50)) == nil)
    }
}

@Suite struct ProgressStatsTests {
    @Test func seasonsRunOctoberToSeptember() {
        let c = Calendar.current
        let jan = c.date(from: DateComponents(year: 2026, month: 1, day: 10))!
        let nov = c.date(from: DateComponents(year: 2025, month: 11, day: 10))!
        let oct26 = c.date(from: DateComponents(year: 2026, month: 10, day: 10))!
        #expect(ProgressStats.seasonStartYear(jan) == 2025 && ProgressStats.seasonStartYear(nov) == 2025 && ProgressStats.seasonStartYear(oct26) == 2026)
        #expect(ProgressStats.seasonLabel(2025) == "2025–26")
    }
    @Test func newTrailStreakIgnoresBackfillAndCountsSkiDays() {
        let c = Calendar.current
        func d(_ n: Int) -> Date { c.date(byAdding: .day, value: n, to: c.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)))! }
        var log: [RunLogEntry] = []
        func add(_ id: String, _ day: Int, first: Bool) { log.append(RunLogEntry(trailID: id, date: d(day), isFirstTime: first)) }
        add("a", 0, first: true); add("b", 5, first: true); add("c", 9, first: true)   // 3 ski days in a row (gaps in calendar days)
        add("a", 12, first: false)                                                       // breaks the streak
        add("d", 20, first: true)
        let days = SkiDay.group(log, meta: [:])
        #expect(ProgressStats.newTrailStreaks(days: days, states: [:]) == .init(current: 1, best: 3))
        var bf = UserTrailState(); bf.backfilled = true
        #expect(ProgressStats.newTrailStreaks(days: days, states: ["b": bf]).best == 1)
    }
    @Test func histogramBins() {
        let b = ProgressStats.histogram(ratings: [(1, true), (10, false), (11, true), (100, true)])
        #expect(b.count == 10 && b[0].total == 2 && b[0].done == 1 && b[1].done == 1 && b[9].done == 1 && b[9].label == "91–100")
    }
}
