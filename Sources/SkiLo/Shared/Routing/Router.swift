import Foundation

/// How hard a route may be.
enum RouteDifficulty: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Trails at or below your Elo.
    case comfortable
    /// Up to 15 above your Elo.
    case stretch
    /// Anything open.
    case any
    var id: Self { self }
    var title: String {
        switch self { case .comfortable: "Comfortable"; case .stretch: "Push it a bit"; case .any: "Anything" }
    }
    var detail: String {
        switch self {
        case .comfortable: "Only trails at or below your Elo"
        case .stretch: "Trails up to 15 above your Elo"
        case .any: "Every open trail"
        }
    }
    func maxRating(elo: Double) -> Int? {
        switch self {
        case .comfortable: max(15, Int(elo.rounded()))
        case .stretch: max(25, Int(elo.rounded()) + 15)
        case .any: nil
        }
    }
}

/// Seconds for an edge, or nil when the edge isn't allowed.
struct RouteCostModel: Sendable {
    var skill: Double
    var ratings: [Trail.ID: Int]
    var maxRating: Int?
    var closedTrails: Set<Trail.ID> = []
    var closedLifts: Set<Lift.ID> = []
    /// Trails allowed even above `maxRating` (e.g. the trail you asked to ski).
    var alwaysAllowed: Set<Trail.ID> = []

    /// Cruising speed (m/s) on a trail of `rating` for a skier of `skill`.
    static func skiSpeed(rating: Int, skill: Double) -> Double {
        min(max(6 + 0.12 * (skill - Double(rating)), 2.5), 11)
    }

    /// Ride speed (m/s) and typical line + load time (s) for a lift.
    static func liftTiming(_ l: Lift) -> (speed: Double, waitS: Double) {
        switch l.kind {
        case .gondola: (5, 240)
        case .cableCar: (8, 300)
        case .magicCarpet: (0.8, 30)
        case .ropeTow: (2, 60)
        case .chairLift: l.name.localizedCaseInsensitiveContains("express") ? (5, 180) : (2.3, 150)
        }
    }

    static func liftSeconds(_ l: Lift) -> Double {
        let t = liftTiming(l)
        return t.waitS + l.lengthM / t.speed
    }

    func seconds(_ e: RouteGraph.Edge, graph: RouteGraph) -> Double? {
        switch e.kind {
        case .trail(let id):
            if closedTrails.contains(id) { return nil }
            let r = ratings[id] ?? 50
            if let maxRating, r > maxRating, !alwaysAllowed.contains(id) { return nil }
            return e.lengthM / Self.skiSpeed(rating: r, skill: skill)
        case .connector(let cap):
            if let maxRating, cap > maxRating { return nil }
            // Catwalks: glide when flat or downhill, skate/sidestep when climbing.
            return e.riseM > 2 ? e.lengthM / 1.5 + e.riseM * 4 : e.lengthM / 5
        case .walk:
            return 4 + e.lengthM / 1.1 + max(0, e.riseM) * 4
        case .lift(let id):
            if closedLifts.contains(id) { return nil }
            guard let l = graph.liftsByID[id] else { return nil }
            return Self.liftSeconds(l)
        }
    }
}

/// Where a route starts or ends.
enum RoutePlace: Hashable, Codable, Sendable {
    case liftBottom(Lift.ID)
    case liftTop(Lift.ID)
    /// As a start: the top of the trail. As a destination: ski the whole trail.
    case trail(Trail.ID)
    case point(GeoCoordinate)
}

struct RouteLeg: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case ski(Trail.ID)
        case lift(Lift.ID)
        /// Catwalks, skating and short walks between trails and lifts.
        case traverse
    }
    var id: Int
    var kind: Kind
    var coords: [GeoCoordinate]
    var lengthM: Double
    var seconds: Double
    var dropM: Double

    /// Too short to list as its own step.
    var isMinor: Bool { kind == .traverse && lengthM < 60 }
}

struct Route: Hashable, Sendable {
    var legs: [RouteLeg]
    var seconds: Double { legs.reduce(0) { $0 + $1.seconds } }
    var lengthM: Double { legs.reduce(0) { $0 + $1.lengthM } }
    var coords: [GeoCoordinate] { legs.flatMap(\.coords) }
    var trailIDs: [Trail.ID] { legs.compactMap { if case .ski(let id) = $0.kind { id } else { nil } } }
    var liftIDs: [Lift.ID] { legs.compactMap { if case .lift(let id) = $0.kind { id } else { nil } } }
    var skiVerticalM: Double { legs.filter { if case .ski = $0.kind { true } else { false } }.reduce(0) { $0 + max(0, $1.dropM) } }
    static let empty = Route(legs: [])
}

enum RouteError: Error, Equatable, LocalizedError {
    case unknownPlace
    case unreachable
    var errorDescription: String? {
        switch self {
        case .unknownPlace: "That place isn't on the map."
        case .unreachable: "No route within this difficulty. Try allowing harder trails, or reopen a closed lift."
        }
    }
}

/// Route finding on a `RouteGraph`.
struct Router: Sendable {
    let graph: RouteGraph

    init(catalog: TrailCatalog) { graph = RouteGraph(catalog: catalog) }
    init(graph: RouteGraph) { self.graph = graph }

    /// The node a route starts from (or, for `.trail` destinations, where the trail begins).
    func node(for place: RoutePlace) -> Int? {
        switch place {
        case .liftBottom(let id): graph.liftEnds[id]?.bottom
        case .liftTop(let id): graph.liftEnds[id]?.top
        case .trail(let id): graph.trailSegments[id]?.first?.first
        case .point(let c): graph.nearestNode(to: c)
        }
    }

    /// The edges of skiing a trail top to bottom, following its segments while they chain.
    func trailRun(_ id: Trail.ID) -> [(from: Int, edge: RouteGraph.Edge)] {
        guard let segs = graph.trailSegments[id], let first = segs.first else { return [] }
        var chain = [first]
        var used = Set([0])
        while let end = chain.last?.last {
            let endC = graph.coords[end]
            guard let next = segs.indices.filter({ !used.contains($0) })
                .min(by: { graph.coords[segs[$0][0]].distance(to: endC) < graph.coords[segs[$1][0]].distance(to: endC) }),
                  graph.coords[segs[next][0]].distance(to: endC) < 60 else { break }
            used.insert(next); chain.append(segs[next])
        }
        var out: [(Int, RouteGraph.Edge)] = []
        for (k, seg) in chain.enumerated() {
            if k > 0, let prevEnd = chain[k - 1].last,
               let e = graph.adjacency[prevEnd].first(where: { $0.to == seg[0] }) {
                out.append((prevEnd, e))
            }
            for i in 0..<(seg.count - 1) {
                if let e = graph.adjacency[seg[i]].first(where: { $0.to == seg[i + 1] }) { out.append((seg[i], e)) }
            }
        }
        return out
    }

    /// Coordinates of skiing a trail top to bottom.
    func runCoords(_ id: Trail.ID) -> [GeoCoordinate] {
        let run = trailRun(id)
        guard let first = run.first else { return [] }
        return [graph.coords[first.from]] + run.map { graph.coords[$0.edge.to] }
    }

    /// Node at the bottom of a trail run (where you are after skiing it).
    func endNode(ofRun id: Trail.ID) -> Int? { trailRun(id).last?.edge.to ?? node(for: .trail(id)) }

    func route(from: RoutePlace, to: RoutePlace, cost: RouteCostModel) throws -> Route {
        guard let src = node(for: from), let dst = node(for: to) else { throw RouteError.unknownPlace }
        var c = cost
        if case .trail(let id) = to { c.alwaysAllowed.insert(id) }
        let result = graph.search(from: src, cost: c, target: dst)
        guard var edges = result.path(to: dst) else { throw RouteError.unreachable }
        if case .trail(let id) = to { edges += trailRun(id) }
        return legs(from: edges, cost: c)
    }

    /// Group consecutive edges into legs (one per trail, lift, or traverse).
    func legs(from edges: [(from: Int, edge: RouteGraph.Edge)], cost: RouteCostModel) -> Route {
        var legs: [RouteLeg] = []
        for (from, e) in edges {
            let kind: RouteLeg.Kind
            switch e.kind {
            case .trail(let id): kind = .ski(id)
            case .lift(let id): kind = .lift(id)
            case .connector, .walk: kind = .traverse
            }
            var allowed = cost
            if case .trail(let id) = e.kind { allowed.alwaysAllowed.insert(id) }
            let s = allowed.seconds(e, graph: graph) ?? 0
            if var last = legs.last, last.kind == kind, !Self.isLift(kind) {
                last.coords.append(graph.coords[e.to])
                last.lengthM += e.lengthM; last.seconds += s; last.dropM -= e.riseM
                legs[legs.count - 1] = last
            } else {
                var coords = [graph.coords[from], graph.coords[e.to]]
                if case .lift(let id) = e.kind, let l = graph.liftsByID[id] { coords = e.riseM < 0 ? l.polyline.reversed() : l.polyline }
                legs.append(RouteLeg(id: legs.count, kind: kind, coords: coords, lengthM: e.lengthM, seconds: s, dropM: -e.riseM))
            }
        }
        return Route(legs: legs)
    }

    private static func isLift(_ k: RouteLeg.Kind) -> Bool { if case .lift = k { true } else { false } }
}
