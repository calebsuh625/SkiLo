import Testing
import Foundation
@testable import HeavenlyTracker

private struct AnchorFile: Decodable {
    struct Entry: Decodable {
        struct Inputs: Decodable {
            var vertical_drop_m: Double
            var max_grade_pct: Double
            var sustained_grade_pct: Double
            var osm_difficulty: String?
            var grooming: String?
            var gladed: Bool
        }
        var name: String
        var expected_rating: Int
        var target: Int?
        var tol: Int?
        var inputs: Inputs
        var ratingInput: RatingInput {
            let g: Grooming
            switch inputs.grooming {
            case "mogul": g = .moguls
            case "classic": g = .groomed
            case "backcountry": g = .backcountry
            default: g = .unknown
            }
            return RatingInput(sustainedGradePct: inputs.sustained_grade_pct, maxGradePct: inputs.max_grade_pct,
                               verticalDropM: inputs.vertical_drop_m,
                               osmDifficulty: inputs.osm_difficulty.flatMap { OSMDifficulty(rawValue: $0) } ?? .unknown,
                               grooming: g, gladed: inputs.gladed)
        }
    }
    var trails: [Entry]
}

private func loadAnchors() throws -> (entries: [AnchorFile.Entry], mods: [String: CuratedModifiers]) {
    let a = try JSONDecoder().decode(AnchorFile.self, from: Data(contentsOf: TestPaths.data("calibration_anchors.json")))
    let m = try JSONDecoder().decode([String: CuratedModifiers].self, from: Data(contentsOf: TestPaths.data("curated_modifiers.json")))
    return (a.trails, m)
}

@Suite("Rating")
struct RatingTests {
    @Test func fixtureExact() throws {
        let (entries, mods) = try loadAnchors()
        #expect(entries.count == 126)
        for e in entries {
            let r = DifficultyRating.rating(e.ratingInput, mods[e.name] ?? .none)
            #expect(r == e.expected_rating, "\(e.name): swift \(r) != expected \(e.expected_rating)")
        }
    }

    @Test func anchorsWithinTolerance() throws {
        let (entries, mods) = try loadAnchors()
        let anchors = entries.filter { $0.target != nil }
        #expect(anchors.count == 29)
        for e in anchors {
            let r = DifficultyRating.rating(e.ratingInput, mods[e.name] ?? .none)
            #expect(abs(r - e.target!) <= e.tol!, "\(e.name): \(r) vs target \(e.target!) +/- \(e.tol!)")
        }
    }

    @Test func workedExamples() throws {
        let gun = RatingInput(sustainedGradePct: 58.9, maxGradePct: 62.3, verticalDropM: 283,
                              osmDifficulty: .expert, grooming: .moguls, gladed: false)
        let gb = DifficultyRating.breakdown(gun)
        #expect(gb.total == 80)
        #expect(abs(gb.raw - 79.7) < 0.15)
        let mott = RatingInput(sustainedGradePct: 19.0, maxGradePct: 19.8, verticalDropM: 121,
                               osmDifficulty: .advanced, grooming: .groomed, gladed: false)
        var mm = CuratedModifiers(); mm.gated = true; mm.traverse = true; mm.narrow = true; mm.cliffExposure = 0.2
        let mb = DifficultyRating.breakdown(mott, mm)
        #expect(mb.total == 60)
        #expect(abs(mb.afterPrior - 31.5) < 0.15)
        #expect(mb.afterGate == 60)
        #expect(mb.components.contains { $0.key == "gate" })
        let mine = RatingInput(sustainedGradePct: 45.7, maxGradePct: 46.6, verticalDropM: 192,
                               osmDifficulty: .intermediate, grooming: .groomed, gladed: false)
        #expect(DifficultyRating.rating(mine) == 52)
    }

    @Test func componentsSumToSoft() throws {
        let (entries, mods) = try loadAnchors()
        for e in entries {
            let b = DifficultyRating.breakdown(e.ratingInput, mods[e.name] ?? .none)
            let sum = b.components.reduce(0) { $0 + $1.points }
            #expect(abs(sum - b.soft) < 0.001, "\(e.name): components \(sum) vs soft \(b.soft)")
            #expect(b.components.map(\.key).prefix(5) == ["base", "maxPitch", "fatigue", "terrain", "hazards"])
        }
    }

    @Test func monotoneInGrade() {
        func r(_ s: Double, _ m: Double) -> Int {
            DifficultyRating.rating(RatingInput(sustainedGradePct: s, maxGradePct: m, verticalDropM: 300,
                                                osmDifficulty: .unknown, grooming: .groomed, gladed: false))
        }
        var prev = 0
        for s in stride(from: 0.0, through: 120.0, by: 1.0) {
            let v = r(s, s + 5)
            #expect(v >= prev, "S=\(s)")
            prev = v
        }
        for sFixed in [10.0, 25.0, 40.0, 70.0] {
            var p = 0
            for m in stride(from: sFixed, through: sFixed + 30, by: 1.0) {
                let v = r(sFixed, m)
                #expect(v >= p, "S=\(sFixed) M=\(m)")
                p = v
            }
        }
    }

    @Test func bounds() {
        var all = CuratedModifiers()
        all.gated = true; all.hikeTo = true; all.chute = true; all.narrow = true; all.cliffExposure = 1
        all.mogulsTypical = true; all.trees = true
        let hi = DifficultyRating.rating(RatingInput(sustainedGradePct: 120, maxGradePct: 132, verticalDropM: 2000,
                                                     osmDifficulty: .expert, grooming: .moguls, gladed: true), all)
        #expect(hi <= 100 && hi >= 95)
        let lo = DifficultyRating.rating(RatingInput(sustainedGradePct: 0, maxGradePct: 0, verticalDropM: 0,
                                                     osmDifficulty: .easy, grooming: .groomed, gladed: false))
        #expect(lo >= 1)
    }

    @Test func publicKnots() {
        #expect(DifficultyRating.base(0) == 0)
        #expect(DifficultyRating.base(120) == 88)
        #expect(DifficultyRating.base(200) == 88)
        #expect(DifficultyRating.base(12.5) == 3.5)
        #expect(DifficultyRating.floors[.expert] == 62 && DifficultyRating.ceilings[.easy] == 30)
    }
}
