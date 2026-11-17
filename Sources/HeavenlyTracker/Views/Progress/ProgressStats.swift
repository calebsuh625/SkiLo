import Foundation

/// Pure helpers behind ProgressScreen (UX_SPEC §5.2).
enum ProgressStats {
    /// Ski season label for a date: Oct–Sep, named by its starting year (2025 → "2025–26").
    static func seasonStartYear(_ d: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.year, .month], from: d)
        return (c.month ?? 1) >= 10 ? c.year! : c.year! - 1
    }
    static func seasonLabel(_ startYear: Int) -> String { "\(startYear)–\(String(format: "%02d", (startYear + 1) % 100))" }

    struct Streaks: Equatable { var current: Int; var best: Int }

    /// New-trail streak: consecutive ski days (not calendar days), each with >= 1 first-time run
    /// on a trail that was not backfilled.
    static func newTrailStreaks(days: [SkiDay], states: [Trail.ID: UserTrailState]) -> Streaks {
        var run = 0, best = 0
        for d in days.sorted(by: { $0.date < $1.date }) {
            let hit = d.entries.contains { $0.isFirstTime && states[$0.trailID]?.backfilled != true }
            run = hit ? run + 1 : 0
            best = max(best, run)
        }
        return Streaks(current: run, best: best)
    }

    struct Bin: Identifiable, Equatable { var lo: Int; var hi: Int; var done: Int; var total: Int
        var id: Int { lo }; var label: String { "\(lo)–\(hi)" } }

    /// Ten rating-decile bins 1–10 … 91–100.
    static func histogram(ratings: [(rating: Int, done: Bool)]) -> [Bin] {
        (0..<10).map { i in
            let lo = i * 10 + 1, hi = i * 10 + 10
            let inBin = ratings.filter { $0.rating >= lo && $0.rating <= hi }
            return Bin(lo: lo, hi: hi, done: inBin.filter(\.done).count, total: inBin.count)
        }
    }
}
