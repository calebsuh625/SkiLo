import Foundation

/// Directions panel state (session only).
struct DirectionsState: Equatable {
    enum End: Equatable { case from, to }
    var isOpen = false
    var from: RoutePlace?
    var to: RoutePlace?
    var difficulty: RouteDifficulty = .stretch
    /// When set, the next map click sets this end of the route.
    var picking: End?
    var route: Route?
    var error: String?
    /// Leg the user is hovering or clicked in the steps list.
    var focusedLeg: Int?
}

/// One choice in the From / To menus.
struct PlaceOption: Identifiable, Hashable {
    enum Group: String, CaseIterable { case lodges = "Lodges", liftTops = "Top of a lift", liftBottoms = "Bottom of a lift", trails = "Trails" }
    var place: RoutePlace
    var title: String
    var group: Group
    var id: String { "\(group.rawValue)|\(title)" }
}

/// Things closed for the day (lift holds, roped trails); the router avoids them.
struct Closures: Equatable, Codable {
    var lifts: Set<Lift.ID> = []
    var trails: Set<Trail.ID> = []
    var dayKey: String = ""
}

extension AppStore {
    // MARK: places

    func lift(_ id: Lift.ID) -> Lift? { router.graph.liftsByID[id] }
    func lift(named name: String) -> Lift? { catalog.lifts.first { $0.name == name } }

    var baseOptions: [PlaceOption] {
        resort.bases.compactMap { b in lift(named: b.liftName).map { PlaceOption(place: .liftBottom($0.id), title: b.name, group: .lodges) } }
    }

    /// Every place the From / To menus offer, grouped.
    var placeOptions: [PlaceOption] {
        let lifts = catalog.lifts.filter { !RouteGraph.isExcluded($0) && !$0.name.hasPrefix("Unnamed") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let trails = catalog.trails.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return baseOptions
            + lifts.map { PlaceOption(place: .liftTop($0.id), title: "Top of \($0.name)", group: .liftTops) }
            + lifts.map { PlaceOption(place: .liftBottom($0.id), title: "Bottom of \($0.name)", group: .liftBottoms) }
            + trails.map { PlaceOption(place: .trail($0.id), title: $0.name, group: .trails) }
    }

    func title(of place: RoutePlace?, asDestination: Bool = false) -> String {
        guard let place else { return "Choose…" }
        switch place {
        case .liftBottom(let id):
            if let base = baseOptions.first(where: { $0.place == place }) { return base.title }
            return "Bottom of \(lift(id)?.name ?? "lift")"
        case .liftTop(let id): return "Top of \(lift(id)?.name ?? "lift")"
        case .trail(let id): return (asDestination ? "Ski " : "Top of ") + (trail(id)?.name ?? id)
        case .point: return "Dropped pin"
        }
    }

    func coordinate(of place: RoutePlace) -> GeoCoordinate? {
        router.node(for: place).map { router.graph.coords[$0] }
    }

    // MARK: routing

    /// Cost model for the current skier: Elo, effective ratings and today's closures.
    func routeCost(_ difficulty: RouteDifficulty) -> RouteCostModel {
        RouteCostModel(skill: elo, ratings: effectiveRatings, maxRating: difficulty.maxRating(elo: elo),
                       closedTrails: closuresToday.trails, closedLifts: closuresToday.lifts)
    }

    func route(from: RoutePlace, to: RoutePlace, difficulty: RouteDifficulty) throws -> Route {
        try router.route(from: from, to: to, cost: routeCost(difficulty))
    }

    /// Highlight a step and frame it on the map.
    func focusMap(on leg: RouteLeg) {
        directions.focusedLeg = leg.id
        guard !leg.coords.isEmpty else { return }
        cameraRequest = .bounds(GeoBounds.containing(leg.coords))
    }

    func legTitle(_ leg: RouteLeg) -> String {
        switch leg.kind {
        case .ski(let id): trail(id)?.name ?? id
        case .lift(let id): lift(id)?.name ?? "Lift"
        case .traverse: leg.dropM < -15 ? "Hike / skate" : "Cat track"
        }
    }

    // MARK: directions panel

    func openDirections(to destination: RoutePlace? = nil, from start: RoutePlace? = nil) {
        section = .map
        directions.isOpen = true
        if let destination { directions.to = destination }
        if let start { directions.from = start }
        if directions.from == nil { directions.from = baseOptions.first?.place }
        recomputeRoute()
    }

    func closeDirections() {
        directions = DirectionsState(difficulty: directions.difficulty)
    }

    func setDirections(_ end: DirectionsState.End, _ place: RoutePlace?) {
        switch end { case .from: directions.from = place; case .to: directions.to = place }
        directions.picking = nil
        recomputeRoute()
    }

    func swapDirections() {
        let f = directions.from
        directions.from = directions.to
        directions.to = f
        recomputeRoute()
    }

    func recomputeRoute() {
        directions.focusedLeg = nil
        guard let from = directions.from, let to = directions.to else { directions.route = nil; directions.error = nil; return }
        do {
            let r = try route(from: from, to: to, difficulty: directions.difficulty)
            let changed = r != directions.route
            directions.route = r
            directions.error = nil
            if changed && !r.coords.isEmpty { cameraRequest = .bounds(GeoBounds.containing(r.coords)) }
        } catch {
            directions.route = nil
            directions.error = error.localizedDescription
        }
    }

    /// The map overlay for whatever is being shown: the directions route, or a planned day.
    var mapRoute: MapRoute? {
        if directions.isOpen, let r = directions.route {
            return MapRoute(route: r, focused: directions.focusedLeg, start: directions.from.flatMap(coordinate(of:)), end: r.coords.last)
        }
        if let plan = shownPlan {
            return MapRoute(route: plan.route, focused: nil, start: plan.route.coords.first, end: plan.route.coords.last)
        }
        return nil
    }

    // MARK: closures

    var closuresToday: Closures {
        closures.dayKey == SkiDay.key(for: .now) ? closures : Closures(dayKey: SkiDay.key(for: .now))
    }
    func setClosed(lift id: Lift.ID, _ closed: Bool) {
        var c = closuresToday
        if closed { c.lifts.insert(id) } else { c.lifts.remove(id) }
        closures = c
        recomputeRoute()
    }
    func setClosed(trail id: Trail.ID, _ closed: Bool) {
        var c = closuresToday
        if closed { c.trails.insert(id) } else { c.trails.remove(id) }
        closures = c
        recomputeRoute()
    }
}

extension MapRoute {
    init(route: Route, focused: Int?, start: GeoCoordinate?, end: GeoCoordinate?) {
        self.init(legs: route.legs.map { l in
            let kind: Leg.Kind
            switch l.kind { case .ski: kind = .ski; case .lift: kind = .lift; case .traverse: kind = .traverse }
            return Leg(kind: kind, coords: l.coords, focused: l.id == focused)
        }, start: start, end: end)
    }
}

// MARK: - Fly-throughs

extension AppStore {
    /// Fly down one trail on the 3D map.
    func flyThrough(trail id: Trail.ID) {
        guard let t = trail(id) else { return }
        let coords = router.runCoords(id)
        guard coords.count >= 2 else { return }
        section = .map
        select(id, showInspector: false)
        flyRequest = FlyRequest(title: t.name, segments: [.init(label: "Ski \(t.name)", kind: .ski, coords: coords)])
    }

    /// Fly along a route: rides up the lifts, skis down the trails.
    func flyThrough(route: Route, title: String) {
        let segments = route.legs.filter { $0.coords.count >= 2 }.map { leg -> FlyRequest.Segment in
            switch leg.kind {
            case .ski: .init(label: "Ski \(legTitle(leg))", kind: .ski, coords: leg.coords)
            case .lift: .init(label: "Ride \(legTitle(leg))", kind: .lift, coords: leg.coords)
            case .traverse: .init(label: legTitle(leg), kind: .traverse, coords: leg.coords)
            }
        }
        guard !segments.isEmpty else { return }
        section = .map
        flyRequest = FlyRequest(title: title, segments: segments)
    }
}
