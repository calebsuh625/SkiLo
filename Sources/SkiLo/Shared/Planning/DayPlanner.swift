import Foundation

/// A planned ski day: the trails in skiing order, each with the route that gets you there.
struct DayPlan: Equatable, Sendable {
    struct Stop: Identifiable, Equatable, Sendable {
        var id: Int
        var trailID: Trail.ID
        /// Getting to the top of the trail, then skiing it.
        var route: Route
        var start: Date
        var finish: Date
        /// False when it ends after the lifts close.
        var fits: Bool
    }
    var startPlace: RoutePlace
    var startTime: Date
    var stops: [Stop]
    /// Back to where the day started.
    var returnRoute: Route
    var finishTime: Date
    /// Targets no route could reach (closures or difficulty).
    var unreachable: [Trail.ID]

    var route: Route {
        var legs = stops.flatMap(\.route.legs) + returnRoute.legs
        for i in legs.indices { legs[i].id = i }
        return Route(legs: legs)
    }
    var skiVerticalM: Double { stops.reduce(0) { $0 + $1.route.skiVerticalM } + returnRoute.skiVerticalM }
    var liftRides: Int { stops.reduce(0) { $0 + $1.route.liftIDs.count } + returnRoute.liftIDs.count }
}

/// Planner inputs (session state of the Today screen).
struct PlannerState: Equatable {
    var targets: [Trail.ID] = []
    var start: RoutePlace?
    var startTime: Date = PlannerState.defaultStart()
    var difficulty: RouteDifficulty = .stretch
    /// Reorder targets for the shortest day (otherwise ski them in the listed order).
    var optimizeOrder = true
    var plan: DayPlan?
    var error: String?
    /// Which day the Today screen is planning: 0 = today, 1 = tomorrow.
    var dayOffset = 0

    /// 9:00 today, or tomorrow once today's lifts have closed.
    static func defaultStart(now: Date = .now, openHour: Int = 9, closeHour: Int = 16, calendar: Calendar = .current) -> Date {
        let hour = calendar.component(.hour, from: now)
        let day = hour >= closeHour ? calendar.date(byAdding: .day, value: 1, to: now)! : now
        let open = calendar.date(bySettingHour: openHour, minute: 0, second: 0, of: day)!
        return hour >= closeHour || now < open ? open : now
    }
}

enum DayPlanner {
    static func plan(targets: [Trail.ID], from start: RoutePlace, startTime: Date, closeTime: Date,
                     optimizeOrder: Bool, router: Router, cost baseCost: RouteCostModel) -> DayPlan {
        var cost = baseCost
        cost.alwaysAllowed.formUnion(targets)
        let unique = targets.reduce(into: [Trail.ID]()) { if !$0.contains($1) { $0.append($1) } }
        guard let startNode = router.node(for: start) else {
            return DayPlan(startPlace: start, startTime: startTime, stops: [], returnRoute: .empty, finishTime: startTime, unreachable: unique)
        }

        var remaining = unique
        var unreachable: [Trail.ID] = []
        var stops: [DayPlan.Stop] = []
        var here = startNode
        var clock = startTime

        while !remaining.isEmpty {
            let search = router.graph.search(from: here, cost: cost)
            // Candidate order: nearest (approach + run) first, or simply the next one listed.
            let candidates = optimizeOrder ? remaining : [remaining[0]]
            var best: (id: Trail.ID, edges: [(from: Int, edge: RouteGraph.Edge)], seconds: Double)?
            for id in candidates {
                guard let top = router.node(for: .trail(id)), let approach = search.path(to: top) else { continue }
                let edges = approach + router.trailRun(id)
                let route = router.legs(from: edges, cost: cost)
                if route.seconds < (best?.seconds ?? .infinity) { best = (id, edges, route.seconds) }
            }
            guard let b = best else {
                // Nothing left is reachable from here (or the listed next one isn't).
                if optimizeOrder { unreachable += remaining; break }
                unreachable.append(remaining.removeFirst())
                continue
            }
            remaining.removeAll { $0 == b.id }
            let route = router.legs(from: b.edges, cost: cost)
            let finish = clock.addingTimeInterval(route.seconds)
            stops.append(DayPlan.Stop(id: stops.count, trailID: b.id, route: route, start: clock, finish: finish, fits: finish <= closeTime))
            clock = finish
            here = b.edges.last?.edge.to ?? here
        }

        var back = Route.empty
        if here != startNode {
            let search = router.graph.search(from: here, cost: cost, target: startNode)
            if let edges = search.path(to: startNode) { back = router.legs(from: edges, cost: cost) }
        }
        return DayPlan(startPlace: start, startTime: startTime, stops: stops, returnRoute: back,
                       finishTime: clock.addingTimeInterval(back.seconds), unreachable: unreachable)
    }
}
