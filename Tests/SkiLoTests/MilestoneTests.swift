import Foundation
import Testing
@testable import SkiLo

@Suite struct MilestoneTests {
    /// Synthetic catalog cloned from the bundled one so the tests do not depend on the full dataset.
    struct Spec { var id: String; var area = "CA"; var sub = "other"; var grooming = "groomed"; var gladed = false; var rating: Int }
    func make(_ specs: [Spec]) throws -> (TrailCatalog, [Trail.ID: Int]) {
        var cat = try CatalogLoader.loadBundled()
        let base = cat.trails[0]
        let enc = try JSONEncoder().encode(base)
        var ratings: [Trail.ID: Int] = [:]
        cat.trails = try specs.map { s in
            var o = try JSONSerialization.jsonObject(with: enc) as! [String: Any]
            o["id"] = s.id; o["name"] = s.id; o["area"] = s.area; o["subArea"] = s.sub
            o["grooming"] = s.grooming; o["gladed"] = s.gladed
            ratings[s.id] = s.rating
            return try JSONDecoder().decode(Trail.self, from: JSONSerialization.data(withJSONObject: o))
        }
        return (cat, ratings)
    }
    func eval(_ id: String, _ d: UserData, _ cat: TrailCatalog, _ r: [Trail.ID: Int]) -> MilestoneEvaluation {
        let m = MilestoneRegistry.all.first { $0.id == id }!
        return MilestoneRegistry.evaluate(m, in: MilestoneContext(userData: d, catalog: cat, ratings: r))
    }

    @Test func registryHasAllFamilies() {
        let ids = Set(MilestoneRegistry.all.map(\.id))
        for id in ["first.green", "first.blue", "first.black", "first.doubleBlack", "all.greens", "all.blues", "all.blacks", "all.doubleBlacks",
                   "trail.gunbarrel", "trail.theFace", "area.mottCanyon", "area.mottComplete", "area.killebrew", "area.bothStates",
                   "first.glade", "first.moguls", "count.25", "count.50", "count.100", "days.10", "half"] { #expect(ids.contains(id), "\(id)") }
        #expect(ids.count == MilestoneRegistry.all.count)
    }

    @Test func bandsUseEffectiveRatingsAndFractions() throws {
        let (cat, r) = try make([.init(id: "g1", rating: 10), .init(id: "g2", rating: 20), .init(id: "b1", rating: 40), .init(id: "k1", rating: 60), .init(id: "x1", rating: 80)])
        var d = Fixtures.userData(done: ["g1"])
        #expect(eval("first.green", d, cat, r) == .achieved)
        #expect(eval("first.blue", d, cat, r) == .locked(fraction: nil))
        #expect(eval("all.greens", d, cat, r) == .locked(fraction: 0.5))
        d = Fixtures.userData(done: ["g1", "g2"])
        #expect(eval("all.greens", d, cat, r) == .achieved)
        // override changes the band: g2 is effectively blue
        var r2 = r; r2["g2"] = 30
        #expect(eval("all.greens", d, cat, r2) == .achieved)   // only g1 is green now, and it is done
        #expect(eval("all.blues", d, cat, r2) == .locked(fraction: 0.5))
        #expect(eval("first.blue", d, cat, r2) == .achieved)
        d = Fixtures.userData(done: ["x1", "k1"])
        #expect(eval("first.doubleBlack", d, cat, r) == .achieved)
        #expect(eval("first.black", d, cat, r) == .achieved)
        #expect(eval("all.doubleBlacks", d, cat, r) == .achieved)
    }

    @Test func areasFeaturesAndCounts() throws {
        var specs: [Spec] = [.init(id: "t-gunbarrel", rating: 70), .init(id: "t-the-face", rating: 72),
                             .init(id: "m1", sub: "mottCanyon", rating: 80), .init(id: "m2", sub: "mottCanyon", rating: 85),
                             .init(id: "k1", sub: "killebrewCanyon", rating: 75),
                             .init(id: "gl", gladed: true, rating: 50), .init(id: "mo", grooming: "moguls", rating: 55)]
        for i in 0..<10 { specs.append(.init(id: "f\(i)", rating: 20)) }
        let (cat, r) = try make(specs)
        #expect(eval("trail.gunbarrel", Fixtures.userData(done: ["t-gunbarrel"]), cat, r) == .achieved)
        #expect(eval("trail.theFace", Fixtures.userData(), cat, r) == .locked(fraction: nil))
        #expect(eval("area.mottCanyon", Fixtures.userData(done: ["m1"]), cat, r) == .achieved)
        #expect(eval("area.mottComplete", Fixtures.userData(done: ["m1"]), cat, r) == .locked(fraction: 0.5))
        #expect(eval("area.mottComplete", Fixtures.userData(done: ["m1", "m2"]), cat, r) == .achieved)
        #expect(eval("area.killebrew", Fixtures.userData(done: ["k1"]), cat, r) == .achieved)
        #expect(eval("first.glade", Fixtures.userData(done: ["gl"]), cat, r) == .achieved)
        #expect(eval("first.moguls", Fixtures.userData(done: ["mo"]), cat, r) == .achieved)
        #expect(eval("count.25", Fixtures.userData(done: (0..<10).map { "f\($0)" }), cat, r) == .locked(fraction: 10.0 / 25))
        // half: 17 trails, 9 done
        let nine = (0..<9).map { "f\($0)" }
        #expect(eval("half", Fixtures.userData(done: nine), cat, r) == .achieved)
        #expect(eval("half", Fixtures.userData(done: Array(nine.prefix(4))), cat, r) != .achieved)
    }

    @Test func bothStatesAndDaysAndNewlyAchieved() throws {
        let (cat, r) = try make([.init(id: "ca", area: "CA", rating: 30), .init(id: "nv", area: "NV", rating: 30)])
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!
        var d = Fixtures.userData()
        d.runLog = [RunLogEntry(trailID: "ca", date: noon), RunLogEntry(trailID: "nv", date: noon.addingTimeInterval(7200))]
        #expect(eval("area.bothStates", d, cat, r) == .achieved)
        d.runLog = [RunLogEntry(trailID: "ca", date: noon), RunLogEntry(trailID: "nv", date: noon.addingTimeInterval(86400 * 2))]
        #expect(eval("area.bothStates", d, cat, r) == .locked(fraction: nil))
        #expect(eval("days.10", d, cat, r) == .locked(fraction: 0.2))
        d.runLog = (0..<10).map { RunLogEntry(trailID: "ca", date: noon.addingTimeInterval(Double($0) * 86400 * 2)) }
        #expect(eval("days.10", d, cat, r) == .achieved)

        var d2 = Fixtures.userData(done: ["ca"])
        let ctx = MilestoneContext(userData: d2, catalog: cat, ratings: r)
        #expect(MilestoneRegistry.newlyAchieved(in: ctx).map(\.id).contains("first.blue"))
        d2.profile.unlockedMilestones["first.blue"] = Date()
        let ctx2 = MilestoneContext(userData: d2, catalog: cat, ratings: r)
        #expect(!MilestoneRegistry.newlyAchieved(in: ctx2).map(\.id).contains("first.blue"))
    }
}
