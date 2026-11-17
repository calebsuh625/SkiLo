import Foundation

/// UX_SPEC §7.5 + DESIGN §6.5/§10. Pure, deterministic.
struct DefaultProgressionEngine: ProgressionEngine {
    var readyWindow: ClosedRange<Int> { -7...7 }

    static let windowDays = 60
    static let halfLifeDays = 30.0
    static let gateSkill = 58
    static let hikeSkill = 65

    // MARK: pure helpers (internal for tests)

    /// 0.5^(ageDays/30)
    static func weight(ageDays: Double) -> Double { pow(0.5, ageDays / halfLifeDays) }

    /// Weighted percentile `p` (0…1): smallest value whose cumulative weight reaches p × total.
    static func weightedPercentile(_ items: [(value: Double, weight: Double)], p: Double) -> Double? {
        guard !items.isEmpty else { return nil }
        let sorted = items.sorted { $0.value < $1.value }
        let total = sorted.reduce(0) { $0 + $1.weight }
        let target = p * total
        var cum = 0.0
        for it in sorted {
            cum += it.weight
            if cum >= target - 1e-9 { return it.value }
        }
        return sorted.last?.value
    }

    /// Mastery of one run: clamp(rating × multiplier, 1, 100) + 4 × (confidence − 3).
    static func mastery(rating: Int, entry: RunLogEntry) -> Double {
        let e = min(100, max(1, Double(rating) * entry.conditions.multiplier))
        return e + 4 * Double(entry.confidence - 3)
    }

    // MARK: ProgressionEngine

    func skillHistory(profile: UserProfile, log: [RunLogEntry], ratings: [Trail.ID: Int]) -> [SkillPoint] {
        let seed = Double(profile.selfAssessedStart)
        var points = [SkillPoint(date: profile.startDate, value: seed, low: max(0, seed - 10), high: min(100, seed + 10), runCount: 0)]
        let cal = Calendar.current
        let rated = log.filter { ratings[$0.trailID] != nil }.sorted { $0.date < $1.date }
        let days = Dictionary(grouping: rated, by: { cal.startOfDay(for: $0.date) })
        var previous = seed
        for day in days.keys.sorted() {
            // Runs up to the end of this day, within the trailing window (by calendar-day age).
            let basis: [(value: Double, weight: Double)] = rated.compactMap { e in
                let runDay = cal.startOfDay(for: e.date)
                guard runDay <= day else { return nil }
                let age = Double(cal.dateComponents([.day], from: runDay, to: day).day ?? 0)
                guard age <= Double(Self.windowDays) else { return nil }
                return (Self.mastery(rating: ratings[e.trailID]!, entry: e), Self.weight(ageDays: age))
            }
            let raw: Double
            if basis.count >= 3 { raw = Self.weightedPercentile(basis, p: 0.8) ?? seed }
            else if let mx = basis.map(\.value).max() { raw = mx - 5 }
            else { raw = seed }
            let value = min(100, max(1, max(raw, 0.9 * previous)))
            previous = value
            let half = Double(10 - min(basis.count, 7))
            points.append(SkillPoint(date: day, value: value, low: max(0, value - half), high: min(100, value + half), runCount: basis.count))
        }
        return points
    }

    func currentSkill(history: [SkillPoint], profile: UserProfile) -> SkillEstimate {
        guard let last = history.last else {
            let v = Double(profile.selfAssessedStart)
            return SkillEstimate(value: v, low: max(0, v - 10), high: min(100, v + 10), basisRuns: 0)
        }
        return SkillEstimate(value: last.value, low: last.low, high: last.high, basisRuns: last.runCount)
    }

    func readiness(rating: Int, modifiers: CuratedModifiers, skill: SkillEstimate) -> Readiness {
        let s = skill.rounded
        let d = rating - s
        var kind: Readiness.Kind = d <= -8 ? .belowYou : d <= 7 ? .ready : d <= 15 ? .stretch : .bigStretch
        var reason: String
        switch kind {
        case .belowYou: reason = "below your level"
        case .ready: reason = "right at your level (Elo \(s))"
        case .stretch: reason = "a \(d)-point stretch — try it on a soft day"
        case .bigStretch: reason = "big stretch (+\(d))"
        }
        if modifiers.gated && s < Self.gateSkill {
            kind = .bigStretch; reason = "behind a gate — build to \(Self.gateSkill) first"
        } else if modifiers.hikeTo && s < Self.hikeSkill {
            kind = .bigStretch; reason = "hike-to — build to \(Self.hikeSkill) first"
        }
        return Readiness(kind: kind, delta: d, reason: reason)
    }

    func readyFor(trails: [Trail], ratings: [Trail.ID: Int], states: [Trail.ID: UserTrailState], skill: SkillEstimate, limit: Int) -> [Trail.ID] {
        let cands: [(id: Trail.ID, name: String, delta: Int)] = trails.compactMap { t in
            guard states[t.id]?.isDone != true, let r = ratings[t.id] else { return nil }
            let rd = readiness(rating: r, modifiers: t.modifiers, skill: skill)
            return rd.kind == .ready ? (t.id, t.name, rd.delta) : nil
        }
        let sorted = cands.sorted {
            let a = abs($0.delta - 3), b = abs($1.delta - 3)
            return a != b ? a < b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return Array(sorted.prefix(max(0, limit)).map(\.id))
    }

    func suggestedNext(bucket: [Trail.ID], trails: [Trail.ID: Trail], ratings: [Trail.ID: Int], states: [Trail.ID: UserTrailState], skill: SkillEstimate) -> (id: Trail.ID, reason: String)? {
        let pending: [(id: Trail.ID, r: Readiness)] = bucket.compactMap { id in
            guard states[id]?.status == .bucket, let t = trails[id], let rating = ratings[id] else { return nil }
            return (id, readiness(rating: rating, modifiers: t.modifiers, skill: skill))
        }
        let ready = pending.filter { $0.r.kind == .ready }
        if !ready.isEmpty {
            let nonNeg = ready.filter { $0.r.delta >= 0 }
            let pick = nonNeg.isEmpty ? ready.max { $0.r.delta < $1.r.delta }! : nonNeg.min { $0.r.delta < $1.r.delta }!
            return (pick.id, pick.r.reason)
        }
        let stretch = pending.filter { $0.r.kind == .stretch || $0.r.kind == .bigStretch }
        if let pick = stretch.min(by: { $0.r.delta < $1.r.delta }) { return (pick.id, pick.r.reason) }
        return nil
    }
}
