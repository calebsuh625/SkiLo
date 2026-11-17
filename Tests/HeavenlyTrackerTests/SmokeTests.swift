import Testing
import Foundation
@testable import HeavenlyTracker

@Suite("Scaffold smoke tests")
struct SmokeTests {
    @Test func bundledCatalogDecodes() throws {
        let c = try Fixtures.bundledCatalog()
        #expect(c.resort == "Heavenly Mountain Resort")
        #expect(c.schemaVersion == 1)
        #expect(!c.trails.isEmpty)
        #expect(c.trails.allSatisfy { $0.id.hasPrefix("t-") })
    }
    @Test func geoCoordinateRoundTrips() throws {
        let c = GeoCoordinate(lat: 38.93, lon: -119.94, ele: 2030.5)
        let data = try JSONEncoder().encode([c])
        #expect(String(data: data, encoding: .utf8) == "[[-119.94,38.93,2030.5]]")
        #expect(try JSONDecoder().decode([GeoCoordinate].self, from: data) == [c])
    }
    @Test func userDataDecodesMissingKeys() throws {
        let d = try JSONDecoder().decode(UserData.self, from: Data("{\"trailStates\":{\"t-x\":{\"status\":\"done\"}}}".utf8))
        #expect(d.state(for: "t-x").isDone)
        #expect(d.state(for: "t-x").notes == "")
    }
    @MainActor @Test func storeMarksDone() throws {
        let s = try Fixtures.makeStore()
        let id = s.catalog.trails[0].id
        s.markDone(id)
        #expect(s.state(for: id).isDone)
        #expect(s.doneCount == 1)
        #expect(s.revision == 1)
    }
}
