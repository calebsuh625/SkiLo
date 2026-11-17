import SwiftUI
import Charts

/// UX_SPEC §5.
struct ProgressScreen: View {
    @Environment(AppStore.self) private var store
    enum RangeKind: String, CaseIterable, Identifiable { case whole = "Whole period", d30 = "Last 30 days", d7 = "Last 7 days"; var id: String { rawValue } }
    @State private var season: Int? = nil          // nil = all time
    @State private var range: RangeKind = .whole

    private var units: Units { store.userData.profile.units }
    private var seasons: [Int] {
        Array(Set(store.userData.runLog.map { ProgressStats.seasonStartYear($0.date) })).sorted(by: >)
    }
    private func inRange(_ d: Date) -> Bool {
        if let s = season, ProgressStats.seasonStartYear(d) != s { return false }
        switch range {
        case .whole: return true
        case .d30: return d >= Calendar.current.date(byAdding: .day, value: -30, to: .now)!
        case .d7: return d >= Calendar.current.date(byAdding: .day, value: -7, to: .now)!
        }
    }

    var body: some View {
        let ratings = store.effectiveRatings
        let fullHistory = store.userData.profile.skillHistory      // Elo per ski day
        let history = fullHistory.filter { $0.runCount == 0 || inRange($0.date) }
        let log = store.userData.runLog.filter { inRange($0.date) }
        let days = SkiDay.group(log, meta: store.userData.skiDays)
        let pair = Self.sideBySide(spacing: 16)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                tiles(fullHistory: fullHistory, days: days)
                card("Elo over time") {
                    SkillChart(points: history, log: log).frame(height: 230)
                }
                pair {
                    card("Completed trails by rating") {
                        RatingHistogram(bins: ProgressStats.histogram(ratings: store.catalog.trails.map { (ratings[$0.id] ?? 0, store.state(for: $0.id).isDone) }))
                            .frame(height: 190)
                        Text("Solid = done · faint = all trails in the range. Click a bar to filter Trails.").font(.caption).foregroundStyle(.secondary)
                    }
                    readyCard
                }
                counts(log: log)
                card("Milestones") { MilestoneGrid() }
            }
            .padding(20)
        }
        .navigationTitle("Progress")
        .toolbar {
            ToolbarItemGroup {
                Picker("Season", selection: $season) {
                    Text("All time").tag(Int?.none)
                    ForEach(seasons, id: \.self) { Text(ProgressStats.seasonLabel($0)).tag(Int?.some($0)) }
                }.pickerStyle(.menu)
                Picker("Range", selection: $range) { ForEach(RangeKind.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
            }
        }
        .onAppear { if seasons.count > 1 && season == nil { season = seasons.first } }
    }

    // MARK: tiles

    private func tiles(fullHistory: [SkillPoint], days: [SkiDay]) -> some View {
        let skill = store.skill
        let startVal: Double = {
            guard let last = fullHistory.last else { return skill.value }
            let from = fullHistory.last(where: { !inRange($0.date) && $0.date < (days.map(\.date).min() ?? last.date) }) ?? fullHistory.first!
            return from.value
        }()
        let delta = Elo.formatDelta(skill.value - startVal)
        let done = store.doneCount, total = store.catalog.trails.count
        func areaDone(_ a: Area) -> String {
            let ts = store.catalog.trails.filter { $0.area == a }
            return "\(a.rawValue) \(ts.filter { store.state(for: $0.id).isDone }.count)/\(ts.count)"
        }
        let streaks = ProgressStats.newTrailStreaks(days: SkiDay.group(store.userData.runLog, meta: [:]), states: store.userData.trailStates)
        // 4 across on the Mac, 2×2 on a phone.
        #if os(iOS)
        let columnCount = 2
        #else
        let columnCount = 4
        #endif
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columnCount), alignment: .leading, spacing: 12) {
            tile("Elo") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Elo.format(skill.value)).font(.system(size: 34, weight: .bold)).monospacedDigit()
                    if let delta { Text(delta.hasPrefix("+") ? "▲ \(delta)" : "▼ \(delta)").font(.callout).foregroundStyle(delta.hasPrefix("+") ? Ramp.doneGreen.color : .red) }
                }
                HStack(spacing: 4) { BandSymbol(band: Band.of(skill.rounded)); Text(Band.of(skill.rounded).title) }.font(.callout)
                Text(skill.isProvisional ? "est. · ±\(Int(((skill.high - skill.low) / 2).rounded()))" : "±\(Int(((skill.high - skill.low) / 2).rounded()))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            tile("Done") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(done) / \(total)").font(.system(size: 26, weight: .bold)).monospacedDigit()
                    Text("\(total == 0 ? 0 : Int((Double(done) / Double(total) * 100).rounded()))%").foregroundStyle(.secondary)
                }
                if store.resortID == "heavenly" {
                    Text("\(areaDone(.california))  \(areaDone(.nevada))").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("at \(store.resort.shortName)").font(.callout).foregroundStyle(.secondary)
                }
            }
            tile("Days on snow") {
                Text("\(days.count)").font(.system(size: 34, weight: .bold)).monospacedDigit()
                Text("\(store.skiDays.count) all time").font(.callout).foregroundStyle(.secondary)
            }
            tile("New-trail streak") {
                Text("\(streaks.current) day\(streaks.current == 1 ? "" : "s")").font(.system(size: 26, weight: .bold)).monospacedDigit()
                Text("best \(streaks.best)").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Two cards side by side on the Mac, stacked on a phone.
    private static func sideBySide(spacing: CGFloat) -> AnyLayout {
        #if os(iOS)
        AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
        #else
        AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
        #endif
    }

    private func tile<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: ready for you

    private var readyCard: some View {
        let ids = store.progression.readyFor(trails: store.catalog.trails, ratings: store.effectiveRatings,
                                             states: store.userData.trailStates, skill: store.skill, limit: 5)
        return card("Ready for you") {
            if ids.isEmpty { Text("Nothing in your ready window left to try.").foregroundStyle(.secondary) }
            ForEach(ids, id: \.self) { id in
                if let t = store.trail(id) {
                    HStack(spacing: 8) {
                        BandSymbol(band: Band.of(store.effectiveRating(t)))
                        Text(t.name).fontWeight(.medium)
                        RatingPill(rating: store.effectiveRating(t), size: .caption)
                        Text(t.grooming == .moguls ? "\(t.areaShort) · moguls" : t.areaShort).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Map ▸") { store.showOnMap(id) }.linkButtonStyle()
                    }
                }
            }
            if !ids.isEmpty {
                HStack { Spacer(); Button("Add all to bucket") { store.addToBucket(ids) } }
            }
        }
    }

    // MARK: counts

    private func counts(log: [RunLogEntry]) -> some View {
        let vert = log.compactMap { store.trail($0.trailID)?.stats.verticalDropM }.reduce(0, +)
        let r = store.effectiveRatings
        return card("Counts") {
            HStack(alignment: .top, spacing: 28) {
                ForEach(Band.allCases, id: \.self) { b in
                    let ts = store.catalog.trails.filter { Band.of(r[$0.id] ?? 0) == b }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) { BandSymbol(band: b); Text(b.title).font(.callout.weight(.medium)) }
                        Text("\(ts.filter { store.state(for: $0.id).isDone }.count) / \(ts.count)").monospacedDigit()
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vert skied").font(.callout.weight(.medium))
                    Text(Format.vert(vert, units)).monospacedDigit()
                }
                Spacer()
            }
        }
    }
}
