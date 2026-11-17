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
    var delta: Double
    var trailID: Trail.ID
}

/// Elo for a skier, where every completed run is a "game" against the trail.
///
/// - A trail's Elo comes from its 1–100 difficulty: 800 (rating 1) … 1988 (rating 100).
/// - The starting Elo is the self-assessed skill on the same scale.
/// - Expected score E = 1 / (1 + 10^((trail − you) / 400)); change = K × (score − E).
///   Clean runs on trails above your level give big gains; easy trails give almost nothing.
/// - Repeats of the same trail count for less (K / √(1 + previous runs of it)), so lapping one
///   run can't farm points.
enum Elo {
    static let base = 800.0
    static let perRatingPoint = 12.0
    static let k = 32.0
    static let floor = 100.0

    static func trailElo(rating: Int) -> Double { base + perRatingPoint * Double(min(max(rating, 1), 100) - 1) }
    static func startElo(selfAssessed: Int) -> Double { trailElo(rating: selfAssessed) }

    static func expected(player: Double, trail: Double) -> Double { 1 / (1 + pow(10, (trail - player) / 400)) }

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
            let d = delta(player: elo, trailRating: r, score: e.score, priorRunsOnTrail: runs[e.trailID, default: 0])
            elo = max(floor, elo + d)
            runs[e.trailID, default: 0] += 1
            out.append(EloPoint(date: e.date, elo: elo, delta: d, trailID: e.trailID))
        }
        return out
    }

    static func current(start: Double, events: [EloEvent], ratings: [Trail.ID: Int]) -> Double {
        history(start: start, events: events, ratings: ratings).last?.elo ?? start
    }
}
