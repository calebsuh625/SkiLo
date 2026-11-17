import SwiftUI

/// One table row: a trail plus the user-dependent values the columns show and sort by.
struct TrailRow: Identifiable, Hashable {
    let trail: Trail
    let status: TrailStatus
    let rating: Int
    let isOverride: Bool
    let timesSkied: Int
    let firstDone: Date?

    var id: Trail.ID { trail.id }
    var band: Band { Band.of(rating) }

    // Sortable scalar fields (KeyPathComparator targets).
    var name: String { trail.name }
    var statusOrder: Int { status == .done ? 0 : status == .bucket ? 1 : 2 }
    var areaSort: String { trail.areaShort + trail.subArea.title }
    var bandOrder: Int { band.rawValue }
    var osmOrder: Int { trail.osmDifficulty.band?.rawValue ?? -1 }
    var length: Double { trail.stats.lengthM }
    var vert: Double { trail.stats.verticalDropM }
    var avgGrade: Double { trail.stats.avgGradePct }
    var maxGrade: Double { trail.stats.maxGradePct }
    var groomingSort: String { trail.grooming.title }
    var gladedOrder: Int { trail.gladed ? 1 : 0 }
    var lift: String { trail.liftName ?? "" }
    var firstDoneSort: Double { firstDone?.timeIntervalSince1970 ?? 0 }
    var topElev: Double { trail.stats.topElevM }
    var bottomElev: Double { trail.stats.bottomElevM }

    @MainActor
    static func rows(for trails: [Trail], store: AppStore) -> [TrailRow] {
        trails.map { t in
            let s = store.state(for: t.id)
            return TrailRow(trail: t, status: s.status, rating: s.ratingOverride ?? t.rating.total,
                            isOverride: s.ratingOverride != nil, timesSkied: s.timesSkied, firstDone: s.firstDoneDate)
        }
    }
}

enum TrailColumn: String, CaseIterable, Identifiable, Codable {
    case status, name, area, rating, band, osm, length, vert, avgGrade, maxGrade, grooming, gladed, lift, times, firstDone, topElev, bottomElev
    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: "St"
        case .name: "Name"
        case .area: "Area"
        case .rating: "Rating"
        case .band: "Band"
        case .osm: "OSM"
        case .length: "Length"
        case .vert: "Vert"
        case .avgGrade: "Avg %"
        case .maxGrade: "Max %"
        case .grooming: "Grooming"
        case .gladed: "Glades"
        case .lift: "Lift"
        case .times: "Times"
        case .firstDone: "First done"
        case .topElev: "Top"
        case .bottomElev: "Bottom"
        }
    }
    var menuTitle: String {
        switch self {
        case .status: "Status"
        case .avgGrade: "Avg grade"
        case .maxGrade: "Max grade"
        case .gladed: "Gladed"
        case .topElev: "Top elevation"
        case .bottomElev: "Bottom elevation"
        default: title
        }
    }
    var comparator: KeyPathComparator<TrailRow> {
        switch self {
        case .status: KeyPathComparator(\.statusOrder)
        case .name: KeyPathComparator(\.name, comparator: .localizedStandard)
        case .area: KeyPathComparator(\.areaSort)
        case .rating: KeyPathComparator(\.rating)
        case .band: KeyPathComparator(\.bandOrder)
        case .osm: KeyPathComparator(\.osmOrder)
        case .length: KeyPathComparator(\.length)
        case .vert: KeyPathComparator(\.vert)
        case .avgGrade: KeyPathComparator(\.avgGrade)
        case .maxGrade: KeyPathComparator(\.maxGrade)
        case .grooming: KeyPathComparator(\.groomingSort)
        case .gladed: KeyPathComparator(\.gladedOrder)
        case .lift: KeyPathComparator(\.lift, comparator: .localizedStandard)
        case .times: KeyPathComparator(\.timesSkied)
        case .firstDone: KeyPathComparator(\.firstDoneSort)
        case .topElev: KeyPathComparator(\.topElev)
        case .bottomElev: KeyPathComparator(\.bottomElev)
        }
    }
    var width: ClosedRange<CGFloat> {
        switch self {
        case .status: 30...36
        case .name: 120...260
        case .area: 40...60
        case .rating: 54...70
        case .band: 40...56
        case .osm: 40...56
        case .length, .vert: 60...90
        case .avgGrade, .maxGrade: 48...70
        case .grooming: 70...100
        case .gladed: 46...70
        case .lift: 90...200
        case .times: 44...64
        case .firstDone: 80...110
        case .topElev, .bottomElev: 70...100
        }
    }
    static let defaultVisible: [TrailColumn] = [.status, .name, .area, .rating, .band, .osm, .length, .vert, .avgGrade, .maxGrade, .grooming, .gladed]

    static func decode(_ json: String) -> [TrailColumn] {
        guard let data = json.data(using: .utf8), let raw = try? JSONDecoder().decode([String].self, from: data) else { return defaultVisible }
        let set = Set(raw.compactMap(TrailColumn.init(rawValue:)))
        return set.isEmpty ? defaultVisible : allCases.filter { set.contains($0) || $0 == .name }
    }
    static func encode(_ cols: [TrailColumn]) -> String {
        (try? JSONEncoder().encode(cols.map(\.rawValue))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

enum TrailGrouping: String, CaseIterable, Identifiable {
    case none, area, band
    var id: String { rawValue }
    var title: String { switch self { case .none: "None"; case .area: "Area"; case .band: "Band" } }
}
