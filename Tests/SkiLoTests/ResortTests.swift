import Foundation
import Testing
@testable import SkiLo

@Suite("Multiple resorts")
struct ResortTests {
    static let catalogs = try! CatalogLoader.loadAllBundled()

    @Test func allThreeResortsLoadWithUniqueIDs() {
        #expect(Self.catalogs.map(\.id) == ["heavenly", "kirkwood", "mtrose"])
        let ids = Self.catalogs.flatMap { $0.trails.map(\.id) }
        #expect(Set(ids).count == ids.count)
        for c in Self.catalogs {
            #expect(c.trails.count > 50, "\(c.id) has \(c.trails.count) trails")
            #expect(CatalogLoader.validate(c).isEmpty, "\(c.id): \(CatalogLoader.validate(c).prefix(3))")
        }
    }

    @Test func everyLodgeNamesARealLift() {
        for c in Self.catalogs {
            let info = ResortInfo.info(for: c.id)
            #expect(info.id == c.id)
            for b in info.bases { #expect(c.lifts.contains { $0.name == b.liftName }, "\(c.id): no lift \(b.liftName)") }
            let b = c.bounds
            #expect((b.minLat...b.maxLat).contains(info.overview.center.lat) && (b.minLon...b.maxLon).contains(info.overview.center.lon))
        }
    }

    @Test(arguments: ["kirkwood", "mtrose"])
    func everyTrailIsReachableFromTheMainLodge(_ id: String) throws {
        let c = try #require(Self.catalogs.first { $0.id == id })
        let router = Router(catalog: c)
        let info = ResortInfo.info(for: id)
        let lodge = try #require(c.lifts.first { $0.name == info.bases[0].liftName })
        let ratings = Dictionary(uniqueKeysWithValues: c.trails.map { ($0.id, $0.rating.total) })
        let r = router.graph.search(from: router.node(for: .liftBottom(lodge.id))!, cost: RouteCostModel(skill: 60, ratings: ratings, maxRating: nil))
        let unreachable = c.trails.filter { t in router.node(for: .trail(t.id)).map { !r.reached($0) } ?? true }.map(\.name)
        #expect(unreachable.isEmpty, "\(id) unreachable: \(unreachable)")
        // And you can always get back to the lodge from the bottom of every trail.
        let lodgeNode = router.node(for: .liftBottom(lodge.id))!
        var stuck: [String] = []
        for t in c.trails {
            guard let end = router.endNode(ofRun: t.id) else { continue }
            if !router.graph.search(from: end, cost: RouteCostModel(skill: 60, ratings: ratings, maxRating: nil), target: lodgeNode).reached(lodgeNode) { stuck.append(t.name) }
        }
        #expect(stuck.isEmpty, "\(id) can't get home from: \(stuck)")
    }

    @Test @MainActor func switchingResortsKeepsEloAndBucketAcrossResorts() throws {
        var d = Fixtures.userData()
        let kw = Self.catalogs[1].trails.first { $0.rating.total > 20 && $0.rating.total < 50 }!
        let store = AppStore(catalogs: Self.catalogs, userData: d, persistence: nil)
        store.markDone(Self.catalogs[0].trails[0].id)
        let eloAfterHeavenly = store.elo
        store.switchResort(to: "kirkwood")
        #expect(store.catalog.id == "kirkwood")
        #expect(store.elo == eloAfterHeavenly)
        store.markDone(kw.id)
        #expect(store.elo != eloAfterHeavenly)
        store.addToBucket([kw.id])
        store.switchResort(to: "heavenly")
        #expect(store.doneCount == 1)                       // Heavenly's own count
        #expect(store.trail(kw.id) != nil)                  // still resolvable for the log / bucket list
        store.showOnMap(kw.id)
        #expect(store.resortID == "kirkwood")
        d = store.userData
        _ = d
    }

    @Test @MainActor func routesAndPicksUseTheCurrentResort() throws {
        let store = AppStore(catalogs: Self.catalogs, userData: Fixtures.userData(), persistence: nil)
        store.switchResort(to: "mtrose")
        let picks = store.todaysPicks
        #expect(!picks.isEmpty)
        #expect(picks.allSatisfy { $0.trailID.hasPrefix("t-mr-") })
        let target = store.catalog.trails.first { $0.rating.total < 40 }!
        store.openDirections(to: .trail(target.id))
        #expect(store.directions.route != nil, "\(store.directions.error ?? "")")
        #expect(store.directions.route?.trailIDs.allSatisfy { $0.hasPrefix("t-mr-") } == true)
    }
}
