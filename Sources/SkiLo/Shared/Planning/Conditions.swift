import Foundation

/// What the snow is likely doing on a given day, from recent and forecast weather.
struct SnowConditions: Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable, Identifiable {
        var id: Self { self }
        case powder, freshSnow, stormy, firm, spring, normal
        var title: String {
            switch self {
            case .powder: "Powder day"
            case .freshSnow: "Fresh snow"
            case .stormy: "Storm skiing"
            case .firm: "Firm / icy"
            case .spring: "Spring snow"
            case .normal: "Packed powder"
            }
        }
        var symbol: String {
            switch self {
            case .powder: "snowflake"
            case .freshSnow: "cloud.snow"
            case .stormy: "wind.snow"
            case .firm: "thermometer.snowflake"
            case .spring: "sun.max"
            case .normal: "mountain.2"
            }
        }
    }
    var kind: Kind
    var windy: Bool
    var cold: Bool
    /// Snow in the 24 h before and during the day (cm).
    var freshCm: Double
    var tips: [String]

    static let unknown = SnowConditions(kind: .normal, windy: false, cold: false, freshCm: 0, tips: [])

    static func assess(_ f: Forecast, day key: String) -> SnowConditions {
        guard let today = f.day(key) else { return .unknown }
        let before = f.days(before: key, count: 3)
        let yesterday = before.last
        let fresh = (yesterday?.snowCm ?? 0) + today.snowCm
        let recent = before.reduce(0) { $0 + $1.snowCm }
        let windy = today.gustMaxKmh >= 55
        let cold = today.tempMaxC <= -8
        let freezeThaw = (yesterday?.tempMaxC ?? -5) > 1 && today.tempMinC < -1

        let kind: Kind
        if today.snowCm >= 15 && today.gustMaxKmh >= 60 { kind = .stormy }
        else if fresh >= 15 { kind = .powder }
        else if fresh >= 5 { kind = .freshSnow }
        else if today.tempMaxC >= 5 { kind = .spring }
        else if recent < 3 && (today.tempMinC <= -3 || freezeThaw) { kind = .firm }
        else { kind = .normal }

        var tips = [defaultTip(for: kind)]
        if windy { tips.append(String(format: "Gusts to %.0f km/h: exposed ridge lifts may close.", today.gustMaxKmh)) }
        if cold { tips.append("Very cold: plan warm-up breaks and favor sunny slopes.") }
        return SnowConditions(kind: kind, windy: windy, cold: cold, freshCm: fresh, tips: tips)
    }
}

/// A trail suggested for the day, and why.
struct TrailPick: Identifiable, Hashable, Sendable {
    var trailID: Trail.ID
    var score: Double
    var reasons: [String]
    var id: Trail.ID { trailID }
}

/// "Today's Pick": trails that suit both the conditions and where you are in your progression.
enum TodaysPick {
    struct Input {
        var trails: [Trail]
        var ratings: [Trail.ID: Int]
        var states: [Trail.ID: UserTrailState]
        var elo: Double
        var conditions: SnowConditions
        var closedTrails: Set<Trail.ID> = []
    }

    static func picks(_ input: Input, count: Int = 8) -> [TrailPick] {
        let tops = input.trails.map(\.stats.topElevM).sorted()
        let highTop = tops.isEmpty ? .infinity : tops[Int(Double(tops.count - 1) * 0.75)]
        let scored = input.trails.compactMap { t -> TrailPick? in
            guard !input.closedTrails.contains(t.id) else { return nil }
            return score(t, input: input, highTop: highTop)
        }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.trailID < $1.trailID }

        // Spread the picks around the mountain: at most 3 per sub-area (or per lift where
        // a resort has no sub-areas).
        var perArea: [String: Int] = [:]
        var out: [TrailPick] = []
        let byID = Dictionary(input.trails.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for p in scored {
            guard let t = byID[p.trailID] else { continue }
            let key = t.subArea == .other ? "lift:" + (t.liftName ?? "") : t.subArea.rawValue
            if perArea[key, default: 0] >= 3 { continue }
            perArea[key, default: 0] += 1
            out.append(p)
            if out.count == count { break }
        }
        return out
    }

    static func score(_ t: Trail, input: Input, highTop: Double) -> TrailPick? {
        let rating = input.ratings[t.id] ?? t.rating.total
        let margin = Double(rating) - input.elo
        guard margin <= 15 else { return nil }
        var s = 0.0
        var why: [String] = []
        let c = input.conditions

        // Ability
        if margin >= -10 && margin <= 6 { s += 3; why.append("Right at your level") }
        else if margin > 6 { s += 2; why.append("A stretch: good for your Elo") }
        else if margin >= -30 { s += 1 }

        // Conditions
        let groomed = t.grooming == .groomed
        let bumps = t.grooming == .moguls
        let aspect = t.stats.aspectDeg
        let southWest = aspect >= 135 && aspect <= 315
        let north = aspect >= 315 || aspect <= 45
        let high = t.stats.topElevM >= highTop
        switch c.kind {
        case .powder, .freshSnow:
            if !groomed || t.gladed { s += c.kind == .powder ? 3 : 2; why.append(t.gladed ? "Trees hold the fresh snow" : "Ungroomed: fresh snow stays soft") }
            if c.kind == .powder && t.stats.avgGradePct > 25 && margin <= 5 { s += 1; why.append("Steep enough to float") }
        case .stormy:
            if t.gladed { s += 3; why.append("Trees give visibility in a storm") }
            if high { s -= 2 }
        case .firm:
            if groomed { s += 3; why.append("Groomed: edges will grip") }
            if bumps { s -= 3 }
            if t.stats.maxGradePct > 45 { s -= 2 }
            if margin > 0 { s -= 2 }
        case .spring:
            if southWest { s += 2; why.append("Sun-softened by late morning") }
            if north { s -= 1 }
            if bumps { s += 1; why.append("Soft spring bumps") }
        case .normal:
            if margin > 0 { s += 1 }
        }
        if c.windy && high { s -= 2; why.append("Exposed if the wind picks up") }
        else if c.windy { s += 1 }
        if c.cold && southWest { s += 1; why.append("Sunny side on a cold day") }

        // Progress
        let st = input.states[t.id] ?? UserTrailState()
        if st.bucketedAt != nil && !st.isDone { s += 2.5; why.insert("On your bucket list", at: 0) }
        else if !st.isDone { s += 1.5; why.append("New to you") }
        else if st.timesSkied >= 5 { s -= 1 }

        // Prefer real runs over tiny links.
        if t.stats.lengthM < 250 { s -= 1.5 }
        return TrailPick(trailID: t.id, score: s, reasons: Array(why.prefix(3)))
    }
}
