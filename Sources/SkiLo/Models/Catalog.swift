import Foundation

struct TrailCatalog: Codable, Sendable {
    var schemaVersion: Int
    var resort: String
    var generatedAt: String
    var source: Provenance
    var ratingEngineVersion: String
    var bounds: GeoBounds
    var trails: [Trail]
    var connectors: [Connector]
    var lifts: [Lift]
    var boundary: [[GeoCoordinate]]

    var trailsByID: [Trail.ID: Trail] { Dictionary(uniqueKeysWithValues: trails.map { ($0.id, $0) }) }
}

struct Provenance: Codable, Hashable, Sendable {
    var osm: String
    var license: String
    var osmTimestamp: String
    var elevation: String
    var pipeline: String
    var modifiersVersion: String
}

enum Area: String, Codable, CaseIterable, Hashable, Sendable {
    case california = "CA", nevada = "NV"
    var title: String { self == .california ? "California" : "Nevada" }
}

enum SubArea: String, Codable, CaseIterable, Hashable, Sendable {
    case gunbarrelFace, skyCanyonPowderbowl, tamarackTop
    case dipperComet, olympicStagecoach, boulderGalaxyNorthBowl
    case mottCanyon, killebrewCanyon
    case other
    var title: String {
        switch self {
        case .gunbarrelFace: "Gunbarrel / Face"
        case .skyCanyonPowderbowl: "Sky / Canyon / Powderbowl"
        case .tamarackTop: "Tamarack / Top"
        case .dipperComet: "Dipper / Comet"
        case .olympicStagecoach: "Olympic / Stagecoach"
        case .boulderGalaxyNorthBowl: "Boulder / Galaxy / North Bowl"
        case .mottCanyon: "Mott Canyon"
        case .killebrewCanyon: "Killebrew Canyon"
        case .other: "Other"
        }
    }
}

enum OSMDifficulty: String, Codable, CaseIterable, Hashable, Sendable {
    case easy, intermediate, advanced, expert, unknown
    var band: Band? {
        switch self {
        case .easy: .green
        case .intermediate: .blue
        case .advanced: .black
        case .expert: .doubleBlack
        case .unknown: nil
        }
    }
}

enum Grooming: String, Codable, CaseIterable, Hashable, Sendable {
    case groomed, moguls, backcountry, unknown
    var title: String {
        switch self {
        case .groomed: "Groomed"
        case .moguls: "Moguls"
        case .backcountry: "Backcountry"
        case .unknown: "—"
        }
    }
}

/// Derived from the effective rating; never stored. UX_SPEC §8.1 cuts.
enum Band: Int, Codable, CaseIterable, Hashable, Sendable {
    case green = 0, blue, black, doubleBlack
    static func of(_ rating: Int) -> Band { rating < 25 ? .green : rating < 50 ? .blue : rating < 75 ? .black : .doubleBlack }
    var title: String {
        switch self {
        case .green: "Green"
        case .blue: "Blue"
        case .black: "Black"
        case .doubleBlack: "Double Black"
        }
    }
    var symbolName: String {
        switch self {
        case .green: "circle.fill"
        case .blue: "square.fill"
        case .black, .doubleBlack: "diamond.fill"
        }
    }
    var range: ClosedRange<Int> {
        switch self {
        case .green: 1...24
        case .blue: 25...49
        case .black: 50...74
        case .doubleBlack: 75...100
        }
    }
}

enum LiftKind: String, Codable, Hashable, Sendable {
    case chairLift = "chair_lift", gondola, cableCar = "cable_car", magicCarpet = "magic_carpet", ropeTow = "rope_tow"
}

struct TrailStats: Codable, Hashable, Sendable {
    var lengthM: Double
    var verticalDropM: Double
    var topElevM: Double
    var bottomElevM: Double
    var avgGradePct: Double
    var maxGradePct: Double          // steepest 50 m window
    var sustainedGradePct: Double    // steepest 150 m window
    var p90GradePct: Double
    var terrainSlopePctP90: Double
    var aspectDeg: Double
    var maxSegmentLengthM: Double
    var segmentsRelation: String     // single | chained | branches
}

/// JSON form: [distanceM, elevationM, gradePct]
struct ProfileSample: Hashable, Sendable, Codable {
    var distanceM: Double
    var elevationM: Double
    var gradePct: Double
    init(distanceM: Double, elevationM: Double, gradePct: Double) {
        self.distanceM = distanceM; self.elevationM = elevationM; self.gradePct = gradePct
    }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        distanceM = try c.decode(Double.self); elevationM = try c.decode(Double.self); gradePct = try c.decode(Double.self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(distanceM); try c.encode(elevationM); try c.encode(gradePct)
    }
}

struct Trail: Codable, Identifiable, Hashable, Sendable {
    typealias ID = String            // "t-" + slug(name), e.g. "t-gunbarrel", "t-the-y", "t-100-saddle"
    let id: ID
    let name: String
    let pipelineID: String
    let osmWayIDs: [Int]
    let area: Area
    let areaConfidence: String
    let subArea: SubArea
    let liftName: String?
    let liftAtBottomName: String?
    let osmDifficulty: OSMDifficulty
    let grooming: Grooming
    let gladed: Bool
    let oneway: Bool
    let geometry: [[GeoCoordinate]]  // one polyline per OSM way, top → bottom
    let midpoint: GeoCoordinate
    let top: GeoCoordinate
    let bottom: GeoCoordinate
    let stats: TrailStats
    let profile: [ProfileSample]
    let modifiers: CuratedModifiers
    let expectedRating: Int?
    /// Filled by CatalogLoader (not in JSON).
    var rating: RatingBreakdown = .unrated

    private enum CodingKeys: String, CodingKey {
        case id, name, pipelineID, osmWayIDs, area, areaConfidence, subArea, liftName, liftAtBottomName
        case osmDifficulty, grooming, gladed, oneway, geometry, midpoint, top, bottom, stats, profile, modifiers, expectedRating
    }

    var ratingInput: RatingInput {
        RatingInput(sustainedGradePct: stats.sustainedGradePct, maxGradePct: stats.maxGradePct,
                    verticalDropM: stats.verticalDropM, osmDifficulty: osmDifficulty,
                    grooming: grooming, gladed: gladed)
    }
    var allCoordinates: [GeoCoordinate] { geometry.flatMap { $0 } }
    var bounds: GeoBounds { GeoBounds.containing(allCoordinates) }
}

struct Connector: Codable, Identifiable, Hashable, Sendable {
    let id: String                   // "u-" + osm way id
    let osmWayID: Int
    let name: String
    let nearestTrail: Trail.ID?
    let osmDifficulty: OSMDifficulty
    let polyline: [GeoCoordinate]
}

struct Lift: Codable, Identifiable, Hashable, Sendable {
    typealias ID = String            // "l-" + osm way id
    let id: ID
    let osmWayID: Int
    let name: String
    let kind: LiftKind
    let area: Area
    let polyline: [GeoCoordinate]    // bottom → top
    let bottomElevM: Double
    let topElevM: Double
    let verticalM: Double
    let lengthM: Double
}
