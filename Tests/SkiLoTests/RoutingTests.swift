import Foundation
import Testing
@testable import SkiLo

@Suite("Routing")
struct RoutingTests {
    static let catalog = try! Fixtures.bundledCatalog()
    static let router = Router(catalog: catalog)
    static var ratings: [Trail.ID: Int] { Dictionary(uniqueKeysWithValues: catalog.trails.map { ($0.id, $0.rating.total) }) }
    static func cost(skill: Double = 60, max: Int? = nil) -> RouteCostModel { RouteCostModel(skill: skill, ratings: ratings, maxRating: max) }
    static func lift(_ name: String) -> Lift { catalog.lifts.first { $0.name == name }! }

    @Test func everyTrailIsReachableFromTheGondola() {
        let src = Self.router.node(for: .liftBottom(Self.lift("Heavenly Gondola").id))!
        let r = Self.router.graph.search(from: src, cost: Self.cost())
        let unreachable = Self.catalog.trails.filter { t in
            guard let n = Self.router.node(for: .trail(t.id)) else { return true }
            return !r.reached(n)
        }.map(\.name)
        #expect(unreachable.isEmpty, "unreachable: \(unreachable)")
    }

    @Test func everyLiftTopCanGetBackToSomeLiftBottom() {
        // You can always ski down from the top of every lift (no dead ends).
        let bottoms = Set(Self.router.graph.liftEnds.values.map(\.bottom))
        for (id, ends) in Self.router.graph.liftEnds {
            let r = Self.router.graph.search(from: ends.top, cost: Self.cost())
            let ok = bottoms.contains { $0 != ends.bottom && r.reached($0) } || r.reached(ends.bottom)
            #expect(ok, "stuck at top of \(Self.router.graph.liftsByID[id]!.name)")
        }
    }

    @Test func routeToATrailEndsBySkiingIt() throws {
        let target = Self.catalog.trails.first { $0.name == "Ridge Run" } ?? Self.catalog.trails[0]
        let route = try Self.router.route(from: .liftBottom(Self.lift("Heavenly Gondola").id), to: .trail(target.id), cost: Self.cost())
        #expect(route.legs.first.map { if case .lift = $0.kind { true } else { false } } == true)
        #expect(route.legs.last?.kind == .ski(target.id))
        #expect(route.seconds > 0 && route.seconds < 3 * 3600)
        #expect(!route.liftIDs.isEmpty)
    }

    @Test func difficultyCapIsRespectedExceptForTheDestination() throws {
        let black = Self.catalog.trails.filter { $0.rating.total >= 60 }.max { $0.rating.total < $1.rating.total }!
        let cap = 35
        let route = try Self.router.route(from: .liftBottom(Self.lift("Heavenly Gondola").id), to: .trail(black.id),
                                          cost: RouteCostModel(skill: 30, ratings: Self.ratings, maxRating: 999))
        _ = route
        let capped = try? Self.router.route(from: .liftBottom(Self.lift("Heavenly Gondola").id), to: .trail(black.id),
                                            cost: RouteCostModel(skill: 30, ratings: Self.ratings, maxRating: cap))
        if let capped {
            for id in capped.trailIDs where id != black.id { #expect(Self.ratings[id]! <= cap, "\(id) above cap") }
        }
    }

    @Test func closedLiftIsAvoided() throws {
        let gondola = Self.lift("Heavenly Gondola")
        let dest = RoutePlace.liftTop(Self.lift("Comet Express").id)
        let open = try Self.router.route(from: .liftBottom(Self.lift("Tamarack Express").id), to: dest, cost: Self.cost())
        var c = Self.cost(); c.closedLifts = Set(open.liftIDs.filter { $0 != Self.lift("Comet Express").id })
        if let alt = try? Self.router.route(from: .liftBottom(Self.lift("Tamarack Express").id), to: dest, cost: c) {
            #expect(Set(alt.liftIDs).isDisjoint(with: c.closedLifts))
        }
        _ = gondola
    }

    @Test func unreachableWhenEverythingIsClosed() {
        var c = Self.cost(); c.closedLifts = Set(Self.catalog.lifts.map(\.id))
        #expect(throws: RouteError.unreachable) {
            try Self.router.route(from: .liftBottom(Self.lift("Heavenly Gondola").id), to: .liftTop(Self.lift("Sky Express").id), cost: c)
        }
    }

    @Test func pointResolvesToNearestNode() throws {
        let t = Self.catalog.trails[3]
        let n = Self.router.node(for: .point(t.top))!
        #expect(Self.router.graph.coords[n].distance(to: t.top) < 1)
    }

    @Test func faster_for_better_skiers() {
        #expect(RouteCostModel.skiSpeed(rating: 40, skill: 70) > RouteCostModel.skiSpeed(rating: 40, skill: 30))
    }
}
