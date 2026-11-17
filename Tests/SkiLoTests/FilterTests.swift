import Testing
import Foundation
@testable import SkiLo

@Suite("Filter and Format")
struct FilterTests {
    /// A trail derived from the bundled catalog's first trail by editing its JSON form.
    static func trail(name: String = "Test", area: String = "CA", grooming: String = "groomed", gladed: Bool = false) throws -> Trail {
        let base = try Fixtures.bundledCatalog().trails[0]
        var obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        obj["name"] = name; obj["area"] = area; obj["grooming"] = grooming; obj["gladed"] = gladed
        return try JSONDecoder().decode(Trail.self, from: JSONSerialization.data(withJSONObject: obj))
    }
    static func state(_ s: TrailStatus) -> UserTrailState { var u = UserTrailState(); u.status = s; return u }

    @Test func defaultFilterMatchesEverything() throws {
        let f = TrailFilter()
        #expect(!f.isActive)
        for status in TrailStatus.allCases {
            #expect(f.matches(trail: try Self.trail(), rating: 50, state: Self.state(status), isReady: false))
        }
    }

    @Test func areaFilter() throws {
        var f = TrailFilter(); f.areas = [.nevada]
        #expect(f.isActive)
        #expect(!f.matches(trail: try Self.trail(area: "CA"), rating: 50, state: .init(), isReady: true))
        #expect(f.matches(trail: try Self.trail(area: "NV"), rating: 50, state: .init(), isReady: true))
    }

    @Test func ratingRangeIsInclusive() throws {
        var f = TrailFilter(); f.ratingRange = 50...74
        let t = try Self.trail()
        #expect(!f.matches(trail: t, rating: 49, state: .init(), isReady: false))
        #expect(f.matches(trail: t, rating: 50, state: .init(), isReady: false))
        #expect(f.matches(trail: t, rating: 74, state: .init(), isReady: false))
        #expect(!f.matches(trail: t, rating: 75, state: .init(), isReady: false))
    }

    @Test func statusFilter() throws {
        var f = TrailFilter(); f.statuses = [.bucket, .notDone]
        let t = try Self.trail()
        #expect(f.matches(trail: t, rating: 50, state: Self.state(.bucket), isReady: false))
        #expect(!f.matches(trail: t, rating: 50, state: Self.state(.done), isReady: false))
    }

    @Test func groomingGladedAndReady() throws {
        var f = TrailFilter(); f.grooming = [.moguls]
        #expect(f.matches(trail: try Self.trail(grooming: "moguls"), rating: 50, state: .init(), isReady: false))
        #expect(!f.matches(trail: try Self.trail(grooming: "groomed"), rating: 50, state: .init(), isReady: false))
        f = TrailFilter(); f.gladedOnly = true
        #expect(f.matches(trail: try Self.trail(gladed: true), rating: 50, state: .init(), isReady: false))
        #expect(!f.matches(trail: try Self.trail(gladed: false), rating: 50, state: .init(), isReady: false))
        f = TrailFilter(); f.readyForMe = true
        #expect(f.matches(trail: try Self.trail(), rating: 50, state: .init(), isReady: true))
        #expect(!f.matches(trail: try Self.trail(), rating: 50, state: .init(), isReady: false))
    }

    @Test func searchIsCaseInsensitiveTrimmedAndNotAnActiveFilter() throws {
        var f = TrailFilter(searchText: "  GUN ")
        #expect(!f.isActive)   // search alone is not a "filter" (funnel stays unfilled)
        #expect(f.matches(trail: try Self.trail(name: "Gunbarrel"), rating: 50, state: .init(), isReady: false))
        #expect(!f.matches(trail: try Self.trail(name: "Ellie's"), rating: 50, state: .init(), isReady: false))
        f.searchText = "   "
        #expect(f.matches(trail: try Self.trail(name: "Ellie's"), rating: 50, state: .init(), isReady: false))
    }

    @Test func summaryDescribesActiveFilters() {
        #expect(TrailFilter().summary == "")
        var f = TrailFilter(); f.areas = [.nevada]; f.ratingRange = 50...100
        #expect(f.summary == "NV, 50–100")
        f.statuses = [.done]
        #expect(f.summary == "NV, 50–100, done")
    }

    @Test func bandCuts() {
        #expect(Band.of(24) == .green); #expect(Band.of(25) == .blue)
        #expect(Band.of(49) == .blue); #expect(Band.of(50) == .black)
        #expect(Band.of(74) == .black); #expect(Band.of(75) == .doubleBlack)
    }

    @Test func formatUnits() {
        #expect(Format.length(1500, .imperial) == "0.9 mi")
        #expect(Format.length(1500, .metric) == "1.5 km")
        #expect(Format.elevation(2516, .imperial) == "8,255 ft")
        #expect(Format.elevation(2516, .metric) == "2,516 m")
        #expect(Format.vert(100, .imperial) == "328 ft")
        #expect(Format.grade(31.4) == "31%")
    }

    @Test func columnVisibilityRoundTripsAndKeepsName() {
        let cols: [TrailColumn] = [.rating, .lift]
        let decoded = TrailColumn.decode(TrailColumn.encode(cols))
        #expect(decoded == [.name, .rating, .lift])          // name can never be hidden; canonical order
        #expect(TrailColumn.decode("garbage") == TrailColumn.defaultVisible)
        #expect(TrailColumn.defaultVisible.count == 12)
        #expect(TrailColumn.allCases.count == 17)
    }

    @Test func breakdownSignFormatting() {
        #expect(RatingBreakdownView.signed(6.2) == "+6")
        #expect(RatingBreakdownView.signed(-2.4) == "\u{2212}2")
        #expect(RatingBreakdownView.signed(0.1) == "0")
    }
}
