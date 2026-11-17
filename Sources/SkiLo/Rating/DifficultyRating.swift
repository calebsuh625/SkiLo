import Foundation

/// RATING_METHOD §3 (v1 constants), line-for-line port of §3.10 adapted to `RatingInput` /
/// `RatingBreakdown` (DESIGN §5). No retuning: constants are exactly those in the spec.
enum DifficultyRating {
    static let version = "rating-v1-2026-11-01"

    static let baseKnots: [(Double, Double)] = [
        (0, 0), (10, 2), (15, 5), (20, 10), (25, 16), (30, 24), (35, 32), (40, 40), (45, 47), (50, 53),
        (55, 58), (60, 63), (65, 67), (70, 71), (80, 77), (90, 81), (100, 84), (120, 88)
    ]
    static let floors: [OSMDifficulty: Double] = [.easy: 0, .intermediate: 15, .advanced: 45, .expert: 62]
    static let ceilings: [OSMDifficulty: Double] = [.easy: 30, .intermediate: 58, .advanced: 85, .expert: 100]

    static func clamp(_ x: Double, _ a: Double, _ b: Double) -> Double { min(max(x, a), b) }
    static func ramp(_ x: Double, _ a: Double, _ b: Double) -> Double { clamp((x - a) / (b - a), 0, 1) }

    static func piecewise(_ x: Double, _ knots: [(Double, Double)]) -> Double {
        if x <= knots[0].0 { return knots[0].1 }
        if x >= knots[knots.count - 1].0 { return knots[knots.count - 1].1 }
        for i in 1..<knots.count where x <= knots[i].0 {
            let (x0, y0) = knots[i - 1], (x1, y1) = knots[i]
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        }
        return knots[knots.count - 1].1
    }

    static func base(_ s: Double) -> Double { piecewise(s, baseKnots) }

    private static func n0(_ x: Double) -> String { String(format: "%.0f", x) }

    static func breakdown(_ t: RatingInput, _ m: CuratedModifiers = .none) -> RatingBreakdown {
        let S = t.sustainedGradePct, M = t.maxGradePct, V = t.verticalDropM
        let osm = t.osmDifficulty
        let moguls = m.mogulsTypical ?? (t.grooming == .moguls)
        let trees = m.trees ?? t.gladed

        let baseV = base(S)
        let maxBonus = 0.35 * clamp(M - S, 0, 12) * ramp(S, 20, 30)
        let fatigue = m.traverse ? 0 : min(10, 2.0 * V / 100) * ramp(S, 10, 30)

        var terrain = 0.0
        var terrainParts: [String] = []
        if moguls { terrain += 5 + 0.10 * S; terrainParts.append("Moguls") }
        if trees {
            terrain += 8; terrainParts.append("Trees")
        } else if !moguls {
            if t.grooming == .backcountry || (t.grooming == .unknown && osm == .expert) {
                terrain += 4; terrainParts.append("Ungroomed")
            } else if t.grooming == .unknown && osm == .advanced {
                terrain += 2; terrainParts.append("Ungroomed")
            }
        }

        var hazards = 0.0
        var hazardParts: [String] = []
        if m.chute { hazards += 6; hazardParts.append("chute") }
        else if m.narrow || m.traverse {
            hazards += 3
            hazardParts.append(m.narrow ? "narrow" : "traverse")
        }
        if m.gated { hazards += 4; hazardParts.append("gated") }
        if m.hikeTo { hazards += 3; hazardParts.append("hike-to") }
        let cliff = clamp(m.cliffExposure, 0, 1)
        hazards += 10 * cliff
        if cliff > 0 { hazardParts.append("cliff " + String(format: "%.1f", cliff)) }

        let raw = baseV + maxBonus + fatigue + terrain + hazards
        // .unknown has no entry in floors/ceilings => floor 0, ceiling 100 (no prior).
        let floor = floors[osm] ?? 0
        let ceiling = ceilings[osm] ?? 100
        var p = raw
        if p < floor { p = (p + floor) / 2 }
        if p > ceiling { p = (p + ceiling) / 2 }
        let g = m.gated ? max(p, 60) : p
        let s = g <= 85 ? g : 85 + 15 * (1 - exp(-(g - 85) / 15))
        let total = Int(clamp(s.rounded(.toNearestOrEven), 1, 100))

        var comps: [RatingComponent] = [
            RatingComponent(key: "base", label: "Sustained grade \(n0(S))%", points: baseV, detail: "150 m window"),
            RatingComponent(key: "maxPitch", label: "Max pitch \(n0(M))%", points: maxBonus, detail: "50 m window"),
            RatingComponent(key: "fatigue", label: "Vertical \(n0(V)) m", points: fatigue, detail: "2 pts per 100 m, cap 10"),
            RatingComponent(key: "terrain", label: terrainParts.isEmpty ? "Groomed / open" : terrainParts.joined(separator: " · "),
                            points: terrain, detail: "moguls, trees, ungroomed"),
            RatingComponent(key: "hazards", label: hazardParts.isEmpty ? "None" : hazardParts.joined(separator: " · "),
                            points: hazards, detail: "chute, narrow, gated, hike-to, cliff"),
        ]
        if abs(p - raw) > 0.005 {
            comps.append(RatingComponent(key: "prior", label: "Resort colour",
                                         points: p - raw, detail: "pulled halfway toward the \(osm.rawValue) band"))
        }
        if abs(g - p) > 0.005 {
            comps.append(RatingComponent(key: "gate", label: "Expert gate", points: g - p, detail: "gated terrain is at least 60"))
        }
        if abs(s - g) > 0.005 {
            comps.append(RatingComponent(key: "softCap", label: "Soft cap", points: s - g, detail: "approach to 100 above 85"))
        }
        return RatingBreakdown(total: total, components: comps, raw: raw, afterPrior: p, afterGate: g,
                               soft: s, engineVersion: version)
    }

    static func rating(_ t: RatingInput, _ m: CuratedModifiers = .none) -> Int {
        breakdown(t, m).total
    }
}
