import Testing
import Foundation
@testable import HeavenlyTracker

@Suite("Catalog")
struct CatalogTests {
    @Test func counts() throws {
        let c = try Fixtures.bundledCatalog()
        #expect(c.trails.count == 126)
        #expect(c.connectors.count == 34)
        #expect(c.lifts.count == 23)
        #expect(c.boundary.count == 1)
        #expect((c.boundary.first?.count ?? 0) >= 300)
    }

    @Test func ids() throws {
        let c = try Fixtures.bundledCatalog()
        let ids = c.trails.map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ids { #expect(id.range(of: "^t-[a-z0-9-]+$", options: .regularExpression) != nil, "\(id)") }
        for id in ["t-gunbarrel", "t-the-face", "t-the-y", "t-100-saddle", "t-bill-s"] { #expect(ids.contains(id), "\(id)") }
    }

    @Test func validatesClean() throws {
        let c = try Fixtures.bundledCatalog()
        #expect(CatalogLoader.validate(c).isEmpty)
    }

    @Test func swiftMatchesPython() throws {
        let c = try Fixtures.bundledCatalog()
        for t in c.trails {
            #expect(t.expectedRating != nil)
            #expect(t.rating.total == t.expectedRating, "\(t.id): swift \(t.rating.total) python \(String(describing: t.expectedRating))")
        }
    }

    @Test func areasAndSubAreas() throws {
        let c = try Fixtures.bundledCatalog()
        func n(_ s: SubArea) -> Int { c.trails.filter { $0.subArea == s }.count }
        #expect(n(.mottCanyon) == 14)
        #expect(n(.killebrewCanyon) == 11)
        #expect(c.trailsByID["t-gunbarrel"]?.subArea == .gunbarrelFace)
        #expect(c.trails.filter { $0.area == .california }.count == 50)
        #expect(c.trails.filter { $0.area == .nevada }.count == 76)
    }

    @Test func geometryAndProfiles() throws {
        let c = try Fixtures.bundledCatalog()
        let b = c.bounds
        for t in c.trails {
            #expect(!t.geometry.isEmpty)
            for line in t.geometry {
                #expect(line.count >= 2, "\(t.id)")
                for p in line {
                    #expect(p.ele != nil, "\(t.id) missing ele")
                    #expect(p.lat >= b.minLat && p.lat <= b.maxLat && p.lon >= b.minLon && p.lon <= b.maxLon, "\(t.id) outside bounds")
                }
            }
            #expect(!t.profile.isEmpty, "\(t.id)")
            // non-decreasing: the pipeline emits one duplicate-distance sample at a chain join (t-ridge-bowl)
            for i in t.profile.indices.dropFirst() { #expect(t.profile[i].distanceM >= t.profile[i - 1].distanceM, "\(t.id) profile order") }
            #expect(t.midpoint.distance(to: t.top) < 1000, "\(t.id) midpoint")
        }
    }

    @Test func bandSpread() throws {
        let c = try Fixtures.bundledCatalog()
        func n(_ f: (Int) -> Bool) -> Int { c.trails.filter { f($0.rating.total) }.count }
        #expect(n { $0 < 25 } >= 10)
        #expect(n { $0 >= 25 && $0 < 50 } >= 10)
        #expect(n { $0 >= 50 && $0 < 75 } >= 10)
        #expect(n { $0 >= 75 } >= 10)
    }

    @Test func liveCatalogAnchorsWithinTolerance() throws {
        let c = try Fixtures.bundledCatalog()
        let a = try JSONSerialization.jsonObject(with: Data(contentsOf: TestPaths.data("calibration_anchors.json"))) as! [String: Any]
        var checked = 0
        for e in a["trails"] as! [[String: Any]] {
            guard let target = e["target"] as? Int, let tol = e["tol"] as? Int, let name = e["name"] as? String else { continue }
            let t = try #require(c.trails.first { $0.name == name })
            #expect(abs(t.rating.total - target) <= tol, "\(name): \(t.rating.total) vs \(target) +/- \(tol)")
            checked += 1
        }
        #expect(checked == 29)
    }
}
