import Foundation

/// UX_SPEC §7.6: 14 families (first.*, all.*, trails/areas, bothStates, glade, moguls, counts, days, half).
enum MilestoneRegistry {
    // MARK: helpers
    private static func doneIDs(_ c: MilestoneContext) -> Set<Trail.ID> {
        Set(c.catalog.trails.filter { c.userData.state(for: $0.id).isDone }.map(\.id))
    }
    private static func band(_ t: Trail, _ c: MilestoneContext) -> Band { Band.of(c.ratings[t.id] ?? t.rating.total) }
    private static func fraction(_ done: Int, _ total: Int) -> MilestoneEvaluation {
        total > 0 && done >= total ? .achieved : .locked(fraction: total > 0 ? Double(done) / Double(total) : nil)
    }
    private static func atLeast(_ n: Int, _ done: Int) -> MilestoneEvaluation {
        done >= n ? .achieved : .locked(fraction: Double(done) / Double(n))
    }
    private static func any(_ ok: Bool) -> MilestoneEvaluation { ok ? .achieved : .locked(fraction: nil) }

    private static func bandFirst(_ id: String, _ title: String, _ b: Band, _ sym: String) -> Milestone {
        Milestone(id: id, title: title, symbol: sym, detail: "Mark any \(b.title.lowercased()) trail done") { c in
            let d = doneIDs(c)
            return any(c.catalog.trails.contains { d.contains($0.id) && band($0, c) == b })
        }
    }
    private static func bandAll(_ id: String, _ title: String, _ b: Band) -> Milestone {
        Milestone(id: id, title: title, symbol: "checkmark.seal", detail: "Mark every \(b.title.lowercased()) trail done") { c in
            let d = doneIDs(c)
            let ts = c.catalog.trails.filter { band($0, c) == b }
            return fraction(ts.filter { d.contains($0.id) }.count, ts.count)
        }
    }
    private static func dayHasBothStates(_ c: MilestoneContext) -> Bool {
        let area = Dictionary(uniqueKeysWithValues: c.catalog.trails.map { ($0.id, $0.area) })
        let byDay = Dictionary(grouping: c.userData.runLog, by: { $0.dayKey })
        return byDay.values.contains { entries in
            let a = Set(entries.compactMap { area[$0.trailID] })
            return a.contains(.california) && a.contains(.nevada)
        }
    }

    static let all: [Milestone] = [
        bandFirst("first.green", "First Green", .green, "circle.fill"),
        bandFirst("first.blue", "First Blue", .blue, "square.fill"),
        bandFirst("first.black", "First Black", .black, "diamond.fill"),
        bandFirst("first.doubleBlack", "First Double Black", .doubleBlack, "diamond.fill"),
        bandAll("all.greens", "All Greens", .green),
        bandAll("all.blues", "All Blues", .blue),
        bandAll("all.blacks", "All Blacks", .black),
        bandAll("all.doubleBlacks", "All Double Blacks", .doubleBlack),
        Milestone(id: "trail.gunbarrel", title: "Gunbarrel", symbol: "flame", detail: "Mark Gunbarrel done") { c in
            any(c.userData.state(for: "t-gunbarrel").isDone)
        },
        Milestone(id: "trail.theFace", title: "The Face", symbol: "mountain.2", detail: "Mark The Face done") { c in
            any(c.userData.state(for: "t-the-face").isDone)
        },
        Milestone(id: "area.mottCanyon", title: "Mott Canyon", symbol: "arrow.down.right.circle", detail: "Mark any Mott Canyon trail done") { c in
            any(c.catalog.trails.contains { $0.subArea == .mottCanyon && c.userData.state(for: $0.id).isDone })
        },
        Milestone(id: "area.mottComplete", title: "Mott Canyon, every chute", symbol: "checkmark.seal.fill", detail: "Mark every Mott Canyon trail done") { c in
            let ts = c.catalog.trails.filter { $0.subArea == .mottCanyon }
            return fraction(ts.filter { c.userData.state(for: $0.id).isDone }.count, ts.count)
        },
        Milestone(id: "area.killebrew", title: "Killebrew Canyon", symbol: "arrow.down.right.circle", detail: "Mark any Killebrew Canyon trail done") { c in
            any(c.catalog.trails.contains { $0.subArea == .killebrewCanyon && c.userData.state(for: $0.id).isDone })
        },
        Milestone(id: "area.bothStates", title: "Two States, One Day", symbol: "arrow.left.arrow.right", detail: "Ski in California and Nevada on the same day") { c in
            any(dayHasBothStates(c))
        },
        Milestone(id: "first.glade", title: "Into the Trees", symbol: "tree", detail: "Mark any gladed trail done") { c in
            any(c.catalog.trails.contains { $0.gladed && c.userData.state(for: $0.id).isDone })
        },
        Milestone(id: "first.moguls", title: "Bump Run", symbol: "waveform.path", detail: "Mark any mogul trail done") { c in
            any(c.catalog.trails.contains { $0.grooming == .moguls && c.userData.state(for: $0.id).isDone })
        },
        Milestone(id: "count.25", title: "25 Trails", symbol: "25.circle", detail: "Mark 25 trails done") { c in atLeast(25, doneIDs(c).count) },
        Milestone(id: "count.50", title: "50 Trails", symbol: "50.circle", detail: "Mark 50 trails done") { c in atLeast(50, doneIDs(c).count) },
        Milestone(id: "count.100", title: "100 Trails", symbol: "100.circle", detail: "Mark 100 trails done") { c in atLeast(100, doneIDs(c).count) },
        Milestone(id: "days.10", title: "Ten Days on Snow", symbol: "snowflake", detail: "Log runs on 10 different days") { c in
            atLeast(10, Set(c.userData.runLog.map(\.dayKey)).count)
        },
        Milestone(id: "half", title: "Halfway", symbol: "circle.lefthalf.filled", detail: "Mark half of all trails done") { c in
            let total = c.catalog.trails.count
            guard total > 0 else { return .locked(fraction: nil) }
            let d = doneIDs(c).count
            return Double(d) >= Double(total) / 2 ? .achieved : .locked(fraction: Double(d) / (Double(total) / 2))
        },
    ]

    static func evaluate(_ m: Milestone, in context: MilestoneContext) -> MilestoneEvaluation { m.evaluate(context) }
    /// Achieved now and not yet in profile.unlockedMilestones.
    static func newlyAchieved(in context: MilestoneContext) -> [Milestone] {
        all.filter { context.userData.profile.unlockedMilestones[$0.id] == nil && $0.evaluate(context) == .achieved }
    }
}
