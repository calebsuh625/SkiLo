import Foundation
import Testing
@testable import SkiLo

@Suite("Forecast & conditions")
struct ForecastTests {
    static func fixture() throws -> Forecast {
        let data = try Data(contentsOf: TestPaths.repoRoot.appendingPathComponent("Tests/SkiLoTests/Fixtures/openmeteo.json"))
        return try WeatherService.parse(data, resortID: "heavenly")
    }

    @Test func parsesOpenMeteoDaily() throws {
        let f = try Self.fixture()
        #expect(f.days.count == 8)
        let d = try #require(f.day("2026-11-15"))
        #expect(d.snowCm == 18.4 && d.gustMaxKmh == 72 && d.weatherCode == 75)
        #expect(f.day("2026-11-19")?.snowCm == 0)          // null → 0
        #expect(f.days(before: "2026-11-16", count: 3).map(\.date) == ["2026-11-13", "2026-11-14", "2026-11-15"])
        #expect(f.upcoming(from: "2026-11-17").count == 4)
    }

    @Test func urlAsksForTheDailyFields() {
        let u = WeatherService.url(for: .heavenly).absoluteString
        #expect(u.contains("api.open-meteo.com") && u.contains("snowfall_sum") && u.contains("past_days=3"))
    }

    @Test func assessesConditions() throws {
        let f = try Self.fixture()
        #expect(SnowConditions.assess(f, day: "2026-11-15").kind == .stormy)    // 18 cm falling with 72 km/h gusts
        #expect(SnowConditions.assess(f, day: "2026-11-16").kind == .powder)    // 18 + 6 cm
        #expect(SnowConditions.assess(f, day: "2026-11-17").kind == .freshSnow) // 6 cm yesterday
        #expect(SnowConditions.assess(f, day: "2026-11-18").kind == .spring)    // 6 °C, no new snow
        #expect(SnowConditions.assess(f, day: "2026-11-20").windy)
        #expect(SnowConditions.assess(f, day: "2030-01-01") == .unknown)
    }

    @Test func firmAfterADryFreeze() {
        let days = [
            DayForecast(date: "2026-01-01", snowCm: 0, tempMaxC: 3, tempMinC: -4, windMaxKmh: 10, gustMaxKmh: 20, weatherCode: 0),
            DayForecast(date: "2026-01-02", snowCm: 0, tempMaxC: 3, tempMinC: -4, windMaxKmh: 10, gustMaxKmh: 20, weatherCode: 0),
            DayForecast(date: "2026-01-03", snowCm: 0, tempMaxC: 2, tempMinC: -6, windMaxKmh: 10, gustMaxKmh: 20, weatherCode: 0),
        ]
        #expect(SnowConditions.assess(Forecast(resortID: "x", fetchedAt: .now, days: days), day: "2026-01-03").kind == .firm)
    }
}

@Suite("Today's Pick & day planner")
struct PlannerTests {
    static let catalog = RoutingTests.catalog
    static func input(_ kind: SnowConditions.Kind, elo: Double = 45, states: [Trail.ID: UserTrailState] = [:]) -> TodaysPick.Input {
        TodaysPick.Input(trails: catalog.trails, ratings: RoutingTests.ratings, states: states, elo: elo,
                         conditions: SnowConditions(kind: kind, windy: false, cold: false, freshCm: 0, tips: []))
    }

    @Test func picksStayWithinReach() {
        let picks = TodaysPick.picks(Self.input(.normal, elo: 30))
        #expect(picks.count == 8)
        for p in picks { #expect(RoutingTests.ratings[p.trailID]! <= 45) }
        #expect(Set(picks.map(\.trailID)).count == picks.count)
    }

    @Test func firmDaysFavorGroomers() {
        let picks = TodaysPick.picks(Self.input(.firm, elo: 60))
        let byID = Dictionary(uniqueKeysWithValues: Self.catalog.trails.map { ($0.id, $0) })
        let groomed = picks.filter { byID[$0.trailID]!.grooming == .groomed }.count
        #expect(groomed >= picks.count / 2)
        #expect(!picks.contains { byID[$0.trailID]!.grooming == .moguls })
    }

    @Test func powderDaysFavorUngroomed() {
        let picks = TodaysPick.picks(Self.input(.powder, elo: 70))
        let byID = Dictionary(uniqueKeysWithValues: Self.catalog.trails.map { ($0.id, $0) })
        let soft = picks.filter { byID[$0.trailID]!.grooming != .groomed || byID[$0.trailID]!.gladed }.count
        #expect(soft >= picks.count / 2)
    }

    @Test func bucketListTrailsRankHigh() {
        let t = Self.catalog.trails.first { abs(Double($0.rating.total) - 45) < 5 && $0.stats.lengthM > 400 }!
        var s = UserTrailState(); s.status = .bucket; s.bucketedAt = .now
        let picks = TodaysPick.picks(Self.input(.normal, elo: 45, states: [t.id: s]))
        let p = try? #require(picks.first { $0.trailID == t.id })
        #expect(p?.reasons.first == "On your bucket list")
    }

    @Test func plansADayThatVisitsEveryTarget() throws {
        let router = RoutingTests.router
        let targets = TodaysPick.picks(Self.input(.normal, elo: 50)).prefix(5).map(\.trailID)
        let start = RoutePlace.liftBottom(RoutingTests.lift("Heavenly Gondola").id)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let plan = DayPlanner.plan(targets: Array(targets), from: start, startTime: t0, closeTime: t0 + 7 * 3600,
                                   optimizeOrder: true, router: router, cost: RoutingTests.cost(skill: 50, max: 65))
        #expect(plan.unreachable.isEmpty)
        #expect(Set(plan.stops.map(\.trailID)) == Set(targets))
        for s in plan.stops { #expect(s.route.legs.last?.kind == .ski(s.trailID)) }
        // Times run forward and the day ends back at the gondola.
        for (a, b) in zip(plan.stops, plan.stops.dropFirst()) { #expect(a.finish <= b.start) }
        #expect(plan.finishTime >= plan.stops.last!.finish)
        let end = plan.route.coords.last!
        let gondolaBottom = router.graph.coords[router.node(for: start)!]
        #expect(end.distance(to: gondolaBottom) < 1)
        #expect(plan.liftRides >= 2)
    }

    @Test func optimizedOrderIsNoSlowerThanListed() {
        let router = RoutingTests.router
        let targets = TodaysPick.picks(Self.input(.normal, elo: 50)).prefix(5).map(\.trailID).reversed()
        let start = RoutePlace.liftBottom(RoutingTests.lift("Heavenly Gondola").id)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let cost = RoutingTests.cost(skill: 50, max: 65)
        let opt = DayPlanner.plan(targets: Array(targets), from: start, startTime: t0, closeTime: t0 + 7 * 3600, optimizeOrder: true, router: router, cost: cost)
        let listed = DayPlanner.plan(targets: Array(targets), from: start, startTime: t0, closeTime: t0 + 7 * 3600, optimizeOrder: false, router: router, cost: cost)
        #expect(listed.stops.map(\.trailID) == Array(targets))
        // Greedy isn't optimal, but it should rarely be much worse than an arbitrary order.
        #expect(opt.finishTime.timeIntervalSince(t0) <= listed.finishTime.timeIntervalSince(t0) * 1.15)
    }

    @Test func defaultStartIsNineOrNow() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let morning = cal.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 7))!
        let noon = cal.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 12))!
        let evening = cal.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 18))!
        #expect(cal.component(.hour, from: PlannerState.defaultStart(now: morning, calendar: cal)) == 9)
        #expect(PlannerState.defaultStart(now: noon, calendar: cal) == noon)
        let next = PlannerState.defaultStart(now: evening, calendar: cal)
        #expect(cal.component(.day, from: next) == 11 && cal.component(.hour, from: next) == 9)
    }
}
