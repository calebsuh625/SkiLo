import Foundation

/// Inputs to RATING_METHOD §3 (S, M, V, prior, grooming, glades).
struct RatingInput: Hashable, Sendable {
    var sustainedGradePct: Double
    var maxGradePct: Double
    var verticalDropM: Double
    var osmDifficulty: OSMDifficulty     // .unknown == no prior
    var grooming: Grooming               // .moguls == "mogul", .backcountry, .unknown == nil
    var gladed: Bool
}

/// Verbatim entry of data/curated_modifiers.json (snake_case keys); all keys optional.
struct CuratedModifiers: Codable, Hashable, Sendable {
    var gated = false
    var hikeTo = false
    var chute = false
    var cliffExposure = 0.0            // 0…1
    var narrow = false
    var traverse = false
    var mogulsTypical: Bool? = nil     // nil → grooming == .moguls
    var trees: Bool? = nil             // nil → gladed
    var notes: String? = nil
    var source: String? = nil

    static let none = CuratedModifiers()
    init() {}

    enum CodingKeys: String, CodingKey {
        case gated, chute, narrow, traverse, trees, notes, source
        case hikeTo = "hike_to", cliffExposure = "cliff_exposure", mogulsTypical = "moguls_typical"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gated = try c.decodeIfPresent(Bool.self, forKey: .gated) ?? false
        hikeTo = try c.decodeIfPresent(Bool.self, forKey: .hikeTo) ?? false
        chute = try c.decodeIfPresent(Bool.self, forKey: .chute) ?? false
        cliffExposure = try c.decodeIfPresent(Double.self, forKey: .cliffExposure) ?? 0
        narrow = try c.decodeIfPresent(Bool.self, forKey: .narrow) ?? false
        traverse = try c.decodeIfPresent(Bool.self, forKey: .traverse) ?? false
        mogulsTypical = try c.decodeIfPresent(Bool.self, forKey: .mogulsTypical)
        trees = try c.decodeIfPresent(Bool.self, forKey: .trees)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

struct RatingComponent: Codable, Hashable, Sendable {
    var key: String        // base | maxPitch | fatigue | terrain | hazards | prior | gate | softCap
    var label: String      // "Sustained grade 60%"
    var points: Double     // signed
    var detail: String     // "150 m window"
}

struct RatingBreakdown: Codable, Hashable, Sendable {
    var total: Int                       // 1…100
    var components: [RatingComponent]    // sum == soft (± rounding)
    var raw: Double
    var afterPrior: Double
    var afterGate: Double
    var soft: Double
    var engineVersion: String
    static let unrated = RatingBreakdown(total: 0, components: [], raw: 0, afterPrior: 0, afterGate: 0, soft: 0, engineVersion: "unrated")
}
