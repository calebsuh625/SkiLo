import Foundation

/// The mountain as a directed graph: every trail vertex is a node, trails run downhill (top →
/// bottom, the catalog's order), lifts run bottom → top, connectors (unnamed catwalks) run both
/// ways, and short "walk" links join the ends of ways that don't share a vertex in OSM.
/// Pure and immutable once built; edge costs are applied per search by `RouteCostModel`.
struct RouteGraph: Sendable {
    enum EdgeKind: Hashable, Sendable {
        case trail(Trail.ID)
        case lift(Lift.ID)
        case connector(maxRating: Int)
        case walk
    }
    struct Edge: Sendable {
        let to: Int
        let kind: EdgeKind
        let lengthM: Double
        /// Elevation gained along the edge (negative = downhill).
        let riseM: Double
    }
    struct LiftEnds: Sendable, Hashable { let bottom: Int; let top: Int }

    private(set) var coords: [GeoCoordinate] = []
    private(set) var adjacency: [[Edge]] = []
    /// Node ids of each geometry segment of a trail, top → bottom.
    private(set) var trailSegments: [Trail.ID: [[Int]]] = [:]
    private(set) var liftEnds: [Lift.ID: LiftEnds] = [:]
    let liftsByID: [Lift.ID: Lift]

    /// `snapRadiusM`: ends of ways closer than this to another way are linked to it.
    /// `hikeRadiusM`: a way end with nothing in snap range is linked to the nearest way within this.
    init(catalog: TrailCatalog, snapRadiusM: Double = 60, hikeRadiusM: Double = 250) {
        liftsByID = Dictionary(catalog.lifts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Ways whose ends get snapped: (node ids, polyline index).
        var ways: [[Int]] = []

        for t in catalog.trails {
            var segs: [[Int]] = []
            for seg in t.geometry where seg.count >= 2 {
                let ids = seg.map { addNode($0) }
                for i in 0..<(ids.count - 1) { addEdge(ids[i], ids[i + 1], .trail(t.id)) }
                segs.append(ids)
                ways.append(ids)
            }
            if !segs.isEmpty { trailSegments[t.id] = segs }
        }
        for c in catalog.connectors where c.polyline.count >= 2 {
            let ids = c.polyline.map { addNode($0) }
            let cap = Self.connectorRating(c.osmDifficulty)
            for i in 0..<(ids.count - 1) {
                addEdge(ids[i], ids[i + 1], .connector(maxRating: cap))
                addEdge(ids[i + 1], ids[i], .connector(maxRating: cap))
            }
            ways.append(ids)
        }

        // Spatial index over every way vertex.
        let origin = catalog.bounds.center
        var grid = Grid(origin: origin, cellM: 100)
        var wayOf: [Int: Int] = [:]
        for (w, ids) in ways.enumerated() {
            for n in ids { grid.insert(n, at: coords[n]); wayOf[n] = w }
        }

        // Link way ends to nearby ways.
        for (w, ids) in ways.enumerated() {
            for end in [ids[0], ids[ids.count - 1]] {
                let near = nearestPerWay(to: coords[end], radius: snapRadiusM, grid: grid, wayOf: wayOf, excluding: w)
                if near.isEmpty {
                    if let far = nearestPerWay(to: coords[end], radius: hikeRadiusM, grid: grid, wayOf: wayOf, excluding: w).min(by: { $0.d < $1.d }) {
                        link(end, far.node)
                    }
                } else {
                    for n in near { link(end, n.node) }
                }
            }
        }

        // Lifts: a single ride edge between a bottom and a top station, each linked to the ways
        // that start or end there.
        for l in catalog.lifts where l.polyline.count >= 2 && !Self.isExcluded(l) {
            let b = addNode(l.polyline[0])
            let t = addNode(l.polyline[l.polyline.count - 1])
            adjacency[b].append(Edge(to: t, kind: .lift(l.id), lengthM: l.lengthM, riseM: l.verticalM))
            // Gondolas and trams also carry skiers down (e.g. back to Heavenly Village).
            if l.kind == .gondola || l.kind == .cableCar {
                adjacency[t].append(Edge(to: b, kind: .lift(l.id), lengthM: l.lengthM, riseM: -l.verticalM))
            }
            liftEnds[l.id] = LiftEnds(bottom: b, top: t)
            for station in [b, t] {
                let near = nearestPerWay(to: coords[station], radius: 80, grid: grid, wayOf: wayOf, excluding: -1)
                if near.isEmpty {
                    if let far = nearestPerWay(to: coords[station], radius: hikeRadiusM, grid: grid, wayOf: wayOf, excluding: -1).min(by: { $0.d < $1.d }) {
                        link(station, far.node)
                    }
                } else {
                    for n in near { link(station, n.node) }
                }
            }
        }

        connectIslands(ways: ways)
    }

    /// Terrain like Mott Canyon is entered through hike gates that OSM doesn't draw, which leaves
    /// "islands" no lift reaches. Repeatedly join the closest unreached way top to the reached
    /// network with a hike link until everything is reachable (or the gap is implausibly long).
    private mutating func connectIslands(ways: [[Int]], maxHikeM: Double = 900) {
        let seeds = liftEnds.values.map(\.bottom)
        guard !seeds.isEmpty else { return }
        // Seed with the lift bottom that reaches the most of the mountain.
        let seed = seeds.max { reach(from: [$0]).count < reach(from: [$1]).count }!
        var reached = reach(from: [seed])
        while true {
            let unreachedTops = Set(ways.map { $0[0] }.filter { !reached.contains($0) })
            guard !unreachedTops.isEmpty else { return }
            var best: (top: Int, from: Int, d: Double)?
            for top in unreachedTops {
                for n in reached {
                    let d = coords[top].distance(to: coords[n])
                    if d < (best?.d ?? .infinity) { best = (top, n, d) }
                }
            }
            guard let b = best, b.d <= maxHikeM else { return }
            addEdge(b.from, b.top, .walk)
            reached.formUnion(reach(from: [b.top]))
        }
    }

    /// Nodes reachable along edges, ignoring costs.
    private func reach(from starts: [Int]) -> Set<Int> {
        var seen = Set(starts)
        var stack = starts
        while let n = stack.popLast() {
            for e in adjacency[n] where seen.insert(e.to).inserted { stack.append(e.to) }
        }
        return seen
    }

    var nodeCount: Int { coords.count }

    /// Tubing and other non-skiing lifts never carry a route.
    static func isExcluded(_ l: Lift) -> Bool { l.name.localizedCaseInsensitiveContains("tubing") }

    /// Connectors only carry an OSM difficulty: treat each band as its typical rating.
    static func connectorRating(_ d: OSMDifficulty) -> Int {
        switch d { case .easy, .unknown: 10; case .intermediate: 30; case .advanced: 55; case .expert: 80 }
    }

    // MARK: building helpers

    private mutating func addNode(_ c: GeoCoordinate) -> Int {
        coords.append(c); adjacency.append([])
        return coords.count - 1
    }

    private mutating func addEdge(_ a: Int, _ b: Int, _ kind: EdgeKind) {
        let len = coords[a].distance(to: coords[b])
        adjacency[a].append(Edge(to: b, kind: kind, lengthM: len, riseM: rise(a, b)))
    }

    private mutating func link(_ a: Int, _ b: Int) {
        guard a != b, !adjacency[a].contains(where: { $0.to == b }) else { return }
        addEdge(a, b, .walk); addEdge(b, a, .walk)
    }

    private func rise(_ a: Int, _ b: Int) -> Double {
        guard let ea = coords[a].ele, let eb = coords[b].ele else { return 0 }
        return eb - ea
    }

    private func nearestPerWay(to c: GeoCoordinate, radius: Double, grid: Grid, wayOf: [Int: Int], excluding: Int) -> [(node: Int, d: Double)] {
        var best: [Int: (node: Int, d: Double)] = [:]
        for n in grid.candidates(near: c, radius: radius) {
            guard let w = wayOf[n], w != excluding else { continue }
            let d = c.distance(to: coords[n])
            guard d <= radius else { continue }
            if best[w].map({ d < $0.d }) ?? true { best[w] = (n, d) }
        }
        return Array(best.values)
    }

    // MARK: queries

    /// The node nearest to `c` (any node), or nil for an empty graph.
    func nearestNode(to c: GeoCoordinate) -> Int? {
        var best: (Int, Double)?
        for (i, p) in coords.enumerated() {
            let d = c.distance(to: p)
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    struct SearchResult: Sendable {
        let source: Int
        let seconds: [Double]
        /// For each reached node: (previous node, edge taken).
        let previous: [Int: (Int, Edge)]

        func reached(_ n: Int) -> Bool { seconds[n].isFinite }

        /// Edges from the source to `target`, in order (empty when target == source).
        func path(to target: Int) -> [(from: Int, edge: Edge)]? {
            guard seconds[target].isFinite else { return nil }
            var out: [(Int, Edge)] = []
            var n = target
            while n != source {
                guard let (p, e) = previous[n] else { return nil }
                out.append((p, e))
                n = p
            }
            return out.reversed()
        }
    }

    /// Dijkstra over `cost` (seconds; nil = edge not allowed). Stops early once `target` is settled.
    func search(from source: Int, cost: RouteCostModel, target: Int? = nil) -> SearchResult {
        var dist = [Double](repeating: .infinity, count: coords.count)
        var prev: [Int: (Int, Edge)] = [:]
        var done = [Bool](repeating: false, count: coords.count)
        var heap = MinHeap()
        dist[source] = 0
        heap.push(0, source)
        while let (d, n) = heap.pop() {
            if done[n] { continue }
            done[n] = true
            if n == target { break }
            for e in adjacency[n] {
                guard !done[e.to], let c = cost.seconds(e, graph: self) else { continue }
                let nd = d + c
                if nd < dist[e.to] {
                    dist[e.to] = nd
                    prev[e.to] = (n, e)
                    heap.push(nd, e.to)
                }
            }
        }
        return SearchResult(source: source, seconds: dist, previous: prev)
    }
}

// MARK: - Spatial grid

private struct Grid: Sendable {
    let origin: GeoCoordinate
    let cellM: Double
    private var cells: [Int64: [Int]] = [:]
    private let mPerLon: Double
    private let mPerLat = 110_574.0

    init(origin: GeoCoordinate, cellM: Double) {
        self.origin = origin; self.cellM = cellM
        mPerLon = 111_320 * cos(origin.lat * .pi / 180)
    }

    private func cell(_ c: GeoCoordinate) -> (Int, Int) {
        (Int(floor((c.lon - origin.lon) * mPerLon / cellM)), Int(floor((c.lat - origin.lat) * mPerLat / cellM)))
    }
    private func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y))) }

    mutating func insert(_ id: Int, at c: GeoCoordinate) {
        let (x, y) = cell(c)
        cells[key(x, y), default: []].append(id)
    }

    func candidates(near c: GeoCoordinate, radius: Double) -> [Int] {
        let (x, y) = cell(c)
        let r = Int(ceil(radius / cellM))
        var out: [Int] = []
        for dx in -r...r { for dy in -r...r { out += cells[key(x + dx, y + dy)] ?? [] } }
        return out
    }
}

// MARK: - Binary min-heap

private struct MinHeap {
    private var items: [(Double, Int)] = []
    mutating func push(_ p: Double, _ v: Int) {
        items.append((p, v))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard items[i].0 < items[parent].0 else { break }
            items.swapAt(i, parent); i = parent
        }
    }
    mutating func pop() -> (Double, Int)? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count && items[l].0 < items[m].0 { m = l }
                if r < items.count && items[r].0 < items[m].0 { m = r }
                if m == i { break }
                items.swapAt(i, m); i = m
            }
        }
        return top
    }
}
