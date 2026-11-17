import Foundation

/// One completed run that counts toward Elo. Stored in `UserData.eloEvents`; the Elo itself is
/// always recomputed from these (so undo, delete, edit and rating overrides stay consistent).
struct EloEvent: Codable, Equatable, Hashable, Sendable, Identifiable {
    enum Source: String, Codable, Sendable { case markDone, logRun }
    var id: UUID = UUID()
    var trailID: Trail.ID
    var date: Date
    /// Chess-style result: 1 = clean run ("win"), 0.5 = got down but struggled, 0 = "lost" to it.
    var score: Double
    var source: Source
    /// Set when the event came from a log entry, so editing/deleting that run updates the event.
    var runID: UUID?

    init(id: UUID = UUID(), trailID: Trail.ID, date: Date, score: Double, source: Source, runID: UUID? = nil) {
        self.id = id; self.trailID = trailID; self.date = date; self.score = score; self.source = source; self.runID = runID
    }
}

struct EloPoint: Equatable, Sendable {
    var date: Date
    var elo: Double
    var delta: Double          // actual change after clamping to 1…100
    var trailID: Trail.ID
}

/// Elo for a skier, on the same 1–100 scale as trail difficulty. This *is* the skill rating:
/// it starts at the self-assessed level from onboarding and every completed or logged run moves it.
///
/// - Each run is a "game" against the trail, whose Elo is its difficulty rating (1–100).
/// - Expected score E = 1 / (1 + 10^((trail − you) / spread)); change = K × (score − E).
///   Clean runs on trails above your level give the biggest gains; easy trails give almost nothing.
/// - Repeats of the same trail count for less (K / √(1 + previous runs of it)), so lapping one
///   run can't farm points.
/// - Shown as "est." until `provisionalGames` runs have counted.
enum Elo {
    static let spread = 30.0
    static let k = 4.0
    static let range = 1.0...100.0
    static let provisionalGames = 3

    static func trailElo(rating: Int) -> Double { Double(min(max(rating, 1), 100)) }
    static func startElo(selfAssessed: Int) -> Double { trailElo(rating: selfAssessed) }

    static func expected(player: Double, trail: Double) -> Double { 1 / (1 + pow(10, (trail - player) / spread)) }

    /// Result of a logged run from its 1–5 confidence (3+ = clean).
    static func score(confidence: Int) -> Double {
        switch confidence {
        case ...1: 0.0
        case 2: 0.5
        default: 1.0
        }
    }

    static func delta(player: Double, trailRating: Int, score: Double, priorRunsOnTrail: Int) -> Double {
        let kEff = k / (1 + Double(max(priorRunsOnTrail, 0))).squareRoot()
        return kEff * (score - expected(player: player, trail: trailElo(rating: trailRating)))
    }

    /// Replays events in date order. Events for trails without a rating are skipped.
    static func history(start: Double, events: [EloEvent], ratings: [Trail.ID: Int]) -> [EloPoint] {
        var elo = start
        var runs: [Trail.ID: Int] = [:]
        var out: [EloPoint] = []
        for e in events.sorted(by: { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }) {
            guard let r = ratings[e.trailID] else { continue }
            let before = elo
            elo = min(range.upperBound, max(range.lowerBound, elo + delta(player: elo, trailRating: r, score: e.score, priorRunsOnTrail: runs[e.trailID, default: 0])))
            runs[e.trailID, default: 0] += 1
            out.append(EloPoint(date: e.date, elo: elo, delta: elo - before, trailID: e.trailID))
        }
        return out
    }

    static func current(start: Double, events: [EloEvent], ratings: [Trail.ID: Int]) -> Double {
        history(start: start, events: events, ratings: ratings).last?.elo ?? start
    }

    /// ± band: 10 with no runs, narrowing to 3 after 7+ runs.
    static func uncertainty(games: Int) -> Double { Double(10 - min(games, 7)) }

    /// The skill chart's series: the starting point, then one point per ski day (that day's
    /// closing Elo). `runCount` is the number of runs counted so far, which drives "est.".
    static func skillHistory(profile: UserProfile, events: [EloEvent], ratings: [Trail.ID: Int]) -> [SkillPoint] {
        let start = startElo(selfAssessed: profile.selfAssessedStart)
        func point(_ date: Date, _ v: Double, _ games: Int) -> SkillPoint {
            let half = uncertainty(games: games)
            return SkillPoint(date: date, value: v, low: max(range.lowerBound, v - half), high: min(range.upperBound, v + half), runCount: games)
        }
        var out = [point(profile.startDate, start, 0)]
        let cal = Calendar.current
        var games = 0
        var lastDay: Date?
        for p in history(start: start, events: events, ratings: ratings) {
            games += 1
            // Dated at the day's latest run (not midnight) so it plots after the starting point.
            let day = cal.startOfDay(for: p.date)
            if day == lastDay { out[out.count - 1] = point(p.date, p.elo, games) } else { out.append(point(p.date, p.elo, games)) }
            lastDay = day
        }
        return out
    }

    /// "31.4" — one decimal so every run visibly moves it.
    static func format(_ v: Double) -> String { String(format: "%.1f", v) }
    /// "+0.8" / "−1.2"; nil when the change rounds to zero.
    static func formatDelta(_ d: Double) -> String? {
        let r = (d * 10).rounded() / 10
        guard r != 0 else { return nil }
        return (r > 0 ? "+" : "−") + String(format: "%.1f", abs(r))
    }
}
