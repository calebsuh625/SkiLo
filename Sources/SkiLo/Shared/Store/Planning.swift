import Foundation

/// Today screen: forecast, conditions, picks and the day plan.
extension AppStore {
    // MARK: forecast

    static var cacheDirectory: URL? {
        guard DevHooks.userDataDirectory == nil else { return DevHooks.userDataDirectory?.appendingPathComponent("cache") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SkiLo/cache", isDirectory: true)
    }

    /// Loads (or refreshes) the forecast. Uses the hour-old cache unless `force`.
    func loadForecast(force: Bool = false) {
        if case .loading = forecast { return }
        if !force, let f = forecast.forecast, Date().timeIntervalSince(f.fetchedAt) < 3_600 { return }
        if let fixture = DevHooks.env["HT_FORECAST_FILE"], let data = try? Data(contentsOf: URL(fileURLWithPath: fixture)),
           let f = try? WeatherService.parse(data, resortID: resort.id) {
            forecast = .loaded(f)
            return
        }
        let previous = forecast.forecast
        forecast = .loading
        let resort = self.resort
        let dir = Self.cacheDirectory
        Task { [weak self] in
            do {
                let f = try await WeatherService.load(for: resort, cacheDirectory: dir, forceRefresh: force)
                self?.forecast = .loaded(f)
            } catch {
                if let previous { self?.forecast = .loaded(previous) }
                else { self?.forecast = .failed("Couldn't load the forecast (\(error.localizedDescription)). You can set today's conditions yourself.") }
            }
            self?.rebuildPlanIfNeeded()
        }
    }

    /// "yyyy-MM-dd" of the day being planned (today or tomorrow).
    var planDayKey: String { Self.dayKey(Calendar.current.date(byAdding: .day, value: planner.dayOffset, to: .now) ?? .now) }

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    var planDayForecast: DayForecast? { forecast.forecast?.day(planDayKey) }

    /// Conditions for the planned day: your override, else the forecast's assessment.
    var conditions: SnowConditions {
        if let k = planner.conditionsOverride {
            var c = forecast.forecast.map { SnowConditions.assess($0, day: planDayKey) } ?? .unknown
            c.kind = k
            c.tips = [SnowConditions.defaultTip(for: k)]
            return c
        }
        return forecast.forecast.map { SnowConditions.assess($0, day: planDayKey) } ?? .unknown
    }

    // MARK: picks

    var todaysPicks: [TrailPick] {
        TodaysPick.picks(TodaysPick.Input(trails: catalog.trails, ratings: effectiveRatings, states: userData.trailStates,
                                          elo: elo, conditions: conditions, closedTrails: closuresToday.trails))
    }

    // MARK: plan

    func addToPlan(_ ids: [Trail.ID]) {
        for id in ids where !planner.targets.contains(id) { planner.targets.append(id) }
        rebuildPlan()
    }
    func removeFromPlan(_ id: Trail.ID) {
        planner.targets.removeAll { $0 == id }
        rebuildPlan()
    }
    func movePlanTargets(from: IndexSet, to: Int) {
        planner.targets.move(fromOffsets: from, toOffset: to)
        planner.optimizeOrder = false
        rebuildPlan()
    }
    func clearPlan() {
        planner.targets = []
        planner.plan = nil
        if shownPlan != nil { shownPlan = nil }
    }

    /// Lifts close at the resort's closing hour on the planned day.
    var planCloseTime: Date {
        Calendar.current.date(bySettingHour: resort.liftsCloseHour, minute: 0, second: 0, of: planner.startTime) ?? planner.startTime
    }

    func rebuildPlan() {
        if planner.start == nil { planner.start = baseOptions.first?.place }
        guard let start = planner.start, !planner.targets.isEmpty else { planner.plan = nil; return }
        planner.plan = DayPlanner.plan(targets: planner.targets, from: start, startTime: planner.startTime, closeTime: planCloseTime,
                                       optimizeOrder: planner.optimizeOrder, router: router, cost: routeCost(planner.difficulty))
        if planner.optimizeOrder, let plan = planner.plan {
            // Show the targets in the order they'll be skied.
            planner.targets = plan.stops.map(\.trailID) + plan.unreachable
        }
        if shownPlan != nil { shownPlan = planner.plan }
    }

    func rebuildPlanIfNeeded() { if !planner.targets.isEmpty { rebuildPlan() } }

    func showPlanOnMap() {
        guard let plan = planner.plan else { return }
        closeDirections()
        shownPlan = plan
        section = .map
        let coords = plan.route.coords
        if !coords.isEmpty { cameraRequest = .bounds(GeoBounds.containing(coords)) }
    }

    func flyThroughPlan() {
        guard let plan = planner.plan else { return }
        shownPlan = plan
        flyThrough(route: plan.route, title: "Your day at \(resort.shortName)")
    }

    /// Plain-text itinerary (for Messages / Notes).
    func planText() -> String {
        guard let plan = planner.plan else { return "" }
        var lines = ["\(resort.shortName) day plan — \(plan.startTime.formatted(date: .abbreviated, time: .omitted))"]
        let c = conditions
        lines.append("Conditions: \(c.kind.title)" + (planDayForecast.map { String(format: " · %.0f°/%.0f°C · %.0f cm new", $0.tempMaxC, $0.tempMinC, c.freshCm) } ?? ""))
        lines.append("Start: \(title(of: plan.startPlace)) at \(Format.time(plan.startTime))")
        for s in plan.stops {
            let lifts = s.route.liftIDs.compactMap { lift($0)?.name }
            let via = lifts.isEmpty ? "" : " (via \(lifts.joined(separator: " → ")))"
            lines.append("\(Format.time(s.start))  \(trail(s.trailID)?.name ?? s.trailID) [\(effectiveRating(s.trailID))]\(via)\(s.fits ? "" : " ⚠︎ after lifts close")")
        }
        lines.append("\(Format.time(plan.finishTime))  Back at \(title(of: plan.startPlace))")
        if !plan.unreachable.isEmpty {
            lines.append("Couldn't fit: " + plan.unreachable.compactMap { trail($0)?.name }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

extension SnowConditions {
    static func defaultTip(for k: Kind) -> String {
        switch k {
        case .powder: "Get to ungroomed runs and glades early, before they're tracked out."
        case .freshSnow: "Off-piste and bumps will be soft; groomers are fast."
        case .stormy: "Trees give the best visibility. Upper lifts may go on wind hold."
        case .firm: "Stick to fresh corduroy in the morning and keep your edges sharp."
        case .spring: "Start on east-facing runs, then follow the sun to south and west faces as they soften."
        case .normal: "Good all-round day: a fine time to push your level."
        }
    }
}
