import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Today: the forecast, what the snow is doing, trails that suit it, and a planned day that
/// routes you through them (shown on the map, flown through, or sent to your phone).
struct TodayScreen: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ForecastStrip()
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        ConditionsCard()
                        PicksCard()
                    }
                    .frame(minWidth: 320, maxWidth: .infinity)
                    PlanCard()
                        .frame(minWidth: 360, maxWidth: .infinity)
                }
            }
            .padding(20)
            .frame(maxWidth: 1_100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Today")
        .onAppear {
            // After the lifts close, "today" means planning tomorrow.
            if store.planner.targets.isEmpty, store.planner.dayOffset == 0,
               Calendar.current.component(.hour, from: .now) >= store.resort.liftsCloseHour {
                store.planner.dayOffset = 1
                store.planner.startTime = Self.start(dayOffset: 1, resort: store.resort)
            }
            store.loadForecast()
            if store.planner.start == nil { store.planner.start = store.baseOptions.first?.place }
        }
        .toolbar {
            ToolbarItem {
                Button { store.loadForecast(force: true) } label: { Label("Refresh Forecast", systemImage: "arrow.clockwise") }
                    .help("Refresh the forecast")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.planner.dayOffset == 0 ? "Today at \(store.resort.shortName)" : "Tomorrow at \(store.resort.shortName)")
                    .font(.largeTitle.weight(.bold))
                Text("Your Elo is \(Elo.format(store.elo)). Picks and routes are tuned to it.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Day", selection: Binding(get: { store.planner.dayOffset }, set: { new in
                store.planner.dayOffset = new
                store.planner.startTime = Self.start(dayOffset: new, resort: store.resort)
                store.rebuildPlanIfNeeded()
            })) {
                Text("Today").tag(0)
                Text("Tomorrow").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 180)
        }
    }

    static func start(dayOffset: Int, resort: ResortInfo) -> Date {
        if dayOffset == 0 { return PlannerState.defaultStart(openHour: resort.liftsOpenHour, closeHour: resort.liftsCloseHour) }
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
        return Calendar.current.date(bySettingHour: resort.liftsOpenHour, minute: 0, second: 0, of: tomorrow)!
    }
}

// MARK: - Forecast

private struct ForecastStrip: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        switch store.forecast {
        case .idle, .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading the mountain forecast…").foregroundStyle(.secondary) }
                .frame(height: 96)
        case .failed(let msg):
            Label(msg, systemImage: "icloud.slash").foregroundStyle(.secondary).frame(minHeight: 60)
        case .loaded(let f):
            let days = f.upcoming(from: AppStore.dayKey(.now)).prefix(5)
            HStack(spacing: 10) {
                ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                    DayTile(day: d, title: i == 0 ? "Today" : i == 1 ? "Tomorrow" : Self.weekday(d.date),
                            selected: d.date == store.planDayKey, units: store.userData.profile.units)
                        .onTapGesture {
                            guard i <= 1 else { return }
                            store.planner.dayOffset = i
                            store.planner.startTime = TodayScreen.start(dayOffset: i, resort: store.resort)
                            store.rebuildPlanIfNeeded()
                        }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text("Forecast: Open-Meteo · updated \(Format.time(f.fetchedAt))").font(.caption2).foregroundStyle(.tertiary).offset(y: 16)
            }
        }
    }

    static func weekday(_ key: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: key) else { return key }
        return d.formatted(.dateTime.weekday(.abbreviated))
    }
}

private struct DayTile: View {
    let day: DayForecast
    let title: String
    let selected: Bool
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                Image(systemName: day.symbol).symbolRenderingMode(.multicolor).font(.title3)
            }
            Text(temp(day.tempMaxC) + " / " + temp(day.tempMinC)).font(.title3.weight(.semibold).monospacedDigit())
            HStack(spacing: 10) {
                Label(snow(day.snowCm), systemImage: "snowflake").foregroundStyle(day.snowCm >= 5 ? Color.accentColor : .secondary)
                Label(wind(day.gustMaxKmh), systemImage: "wind").foregroundStyle(day.gustMaxKmh >= 55 ? .orange : .secondary)
            }
            .font(.caption.monospacedDigit())
            Text(day.summary).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
    }

    private func temp(_ c: Double) -> String { units == .imperial ? String(format: "%.0f°", c * 9 / 5 + 32) : String(format: "%.0f°", c) }
    private func snow(_ cm: Double) -> String { units == .imperial ? String(format: "%.1f\"", cm / 2.54) : String(format: "%.0f cm", cm) }
    private func wind(_ kmh: Double) -> String { units == .imperial ? String(format: "%.0f mph", kmh / 1.609) : String(format: "%.0f km/h", kmh) }
}

// MARK: - Conditions

private struct ConditionsCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let c = store.conditions
        Card(title: "Conditions", symbol: c.kind.symbol) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(c.kind.title).font(.title2.weight(.semibold))
                    if c.freshCm >= 1 {
                        Text(String(format: "%.0f cm new", c.freshCm)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Use the forecast") { store.planner.conditionsOverride = nil }
                        Divider()
                        ForEach(SnowConditions.Kind.allCases) { k in
                            Button(k.title) { store.planner.conditionsOverride = k }
                        }
                    } label: { Text(store.planner.conditionsOverride != nil ? "Set by you" : store.forecast.forecast == nil ? "Set conditions" : "From forecast") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("Override the conditions if you know better")
                }
                ForEach(c.tips, id: \.self) { tip in
                    Label(tip, systemImage: "lightbulb").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Picks

private struct PicksCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let picks = store.todaysPicks
        Card(title: "Today's Pick", symbol: "sparkles", trailing: {
            Button("Plan Top 5") { store.addToPlan(picks.prefix(5).map(\.trailID)) }
                .disabled(picks.isEmpty)
                .help("Add the top five picks to your day plan")
        }) {
            VStack(spacing: 0) {
                if picks.isEmpty {
                    Text("Nothing suits today within your reach. Try setting the conditions yourself.").foregroundStyle(.secondary)
                }
                ForEach(picks) { p in
                    if let t = store.trail(p.trailID) {
                        PickRow(trail: t, pick: p)
                        if p.id != picks.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

private struct PickRow: View {
    @Environment(AppStore.self) private var store
    let trail: Trail
    let pick: TrailPick

    var body: some View {
        let inPlan = store.planner.targets.contains(trail.id)
        HStack(alignment: .top, spacing: 10) {
            RatingPill(rating: store.effectiveRating(trail), size: .callout).fixedSize().frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Button(trail.name) { store.select(trail.id, showInspector: true) }.buttonStyle(.plain).font(.body.weight(.medium))
                    if store.state(for: trail.id).isDone { Image(systemName: "checkmark.circle.fill").foregroundStyle(Ramp.doneGreen.color).font(.caption) }
                }
                Text(pick.reasons.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            Text("\(Elo.formatDelta(store.eloPreview(for: trail.id)) ?? "+0.0")").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .help("Elo for a clean run")
            Button {
                inPlan ? store.removeFromPlan(trail.id) : store.addToPlan([trail.id])
            } label: { Image(systemName: inPlan ? "checkmark.circle.fill" : "plus.circle") }
                .buttonStyle(.borderless).font(.title3)
                .foregroundStyle(inPlan ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .help(inPlan ? "Remove from your plan" : "Add to your plan")
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Plan

private struct PlanCard: View {
    @Environment(AppStore.self) private var store
    @State private var addingTrail = false

    var body: some View {
        @Bindable var store = store
        Card(title: "Day Plan", symbol: "map", trailing: {
            if !store.planner.targets.isEmpty { Button("Clear") { store.clearPlan() } }
        }) {
            VStack(alignment: .leading, spacing: 12) {
                settings
                Divider()
                if store.planner.targets.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add trails from Today's Pick, your bucket list, or any trail, and SkiLo routes your day through them.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Add Bucket List") { store.addToPlan(store.bucketPending.filter { store.trail($0) != nil }) }
                                .disabled(store.bucketPending.isEmpty)
                            addButton
                        }
                    }
                } else if let plan = store.planner.plan {
                    PlanTimeline(plan: plan)
                    HStack { addButton; Spacer() }
                    Divider()
                    actions(plan)
                }
            }
        }
    }

    private var settings: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Start").foregroundStyle(.secondary)
                Picker("Start", selection: Binding(get: { store.planner.start }, set: { store.planner.start = $0; store.rebuildPlanIfNeeded() })) {
                    ForEach(store.baseOptions) { Text($0.title).tag(Optional($0.place)) }
                }
                .labelsHidden().fixedSize()
                DatePicker("at", selection: Binding(get: { store.planner.startTime }, set: { store.planner.startTime = $0; store.rebuildPlanIfNeeded() }),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden().fixedSize()
            }
            GridRow {
                Text("Routes").foregroundStyle(.secondary)
                Picker("Difficulty", selection: Binding(get: { store.planner.difficulty }, set: { store.planner.difficulty = $0; store.rebuildPlanIfNeeded() })) {
                    ForEach(RouteDifficulty.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                Toggle("Shortest order", isOn: Binding(get: { store.planner.optimizeOrder }, set: { store.planner.optimizeOrder = $0; store.rebuildPlanIfNeeded() }))
                    .help("Reorder your trails for the least time on lifts and cat tracks")
            }
            GridRow {
                Text("Closed").foregroundStyle(.secondary)
                ClosuresMenu().gridCellColumns(2)
            }
        }
        .controlSize(.small)
    }

    private var addButton: some View {
        PlacePickerButton(title: "Add a trail…", prompt: "") { place in
            if case .trail(let id) = place { store.addToPlan([id]) }
        }
        .fixedSize()
    }

    private func actions(_ plan: DayPlan) -> some View {
        HStack(spacing: 8) {
            Button { store.showPlanOnMap() } label: { Label("Show on Map", systemImage: "map") }
            Button { store.flyThroughPlan() } label: { Label("Fly Through", systemImage: "play.fill") }
            Spacer()
            SendToPhoneButton(plan: plan)
        }
    }
}

private struct ClosuresMenu: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        let closed = store.closuresToday
        let lifts = store.catalog.lifts.filter { !RouteGraph.isExcluded($0) && !$0.name.hasPrefix("Unnamed") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        Menu {
            Section("Lifts on hold or closed today") {
                ForEach(lifts) { l in
                    Toggle(l.name, isOn: Binding(get: { closed.lifts.contains(l.id) }, set: { store.setClosed(lift: l.id, $0); store.rebuildPlanIfNeeded() }))
                }
            }
            if !closed.trails.isEmpty {
                Section("Closed trails") {
                    ForEach(Array(closed.trails).sorted(), id: \.self) { id in
                        Button("Reopen \(store.trail(id)?.name ?? id)") { store.setClosed(trail: id, false); store.rebuildPlanIfNeeded() }
                    }
                }
            }
        } label: {
            let n = closed.lifts.count + closed.trails.count
            Text(n == 0 ? "Everything open" : "\(n) closed today")
        }
        .fixedSize()
        .help("Mark lifts closed (wind holds, maintenance) and routes avoid them")
    }
}

/// The ordered stops with times; drag to reorder, × to remove.
struct PlanTimeline: View {
    @Environment(AppStore.self) private var store
    let plan: DayPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            timeRow(Format.time(plan.startTime), symbol: "figure.skiing.downhill", tint: .green) {
                Text("Start at \(store.title(of: plan.startPlace))").font(.callout.weight(.medium))
            }
            ForEach(plan.stops) { s in
                if let t = store.trail(s.trailID) {
                    timeRow(Format.time(s.start), symbol: nil, tint: .accentColor) {
                        HStack(alignment: .top, spacing: 8) {
                            RatingPill(rating: store.effectiveRating(t), size: .caption).fixedSize()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).font(.callout.weight(.medium))
                                Text(approach(s)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                if !s.fits {
                                    Label("Ends after the lifts close", systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.orange)
                                }
                                if s.needsHarderTerrain {
                                    Label("Getting here takes harder trails than your limit", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 4)
                            Button { store.removeFromPlan(t.id) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.tertiary).help("Remove from plan")
                        }
                    }
                }
            }
            timeRow(Format.time(plan.finishTime), symbol: "flag.checkered", tint: .red) {
                Text("Back at \(store.title(of: plan.startPlace))").font(.callout.weight(.medium))
            }
            if !plan.unreachable.isEmpty {
                Label("No route to " + plan.unreachable.compactMap { store.trail($0)?.name }.joined(separator: ", ") + " within this difficulty or with today's closures.",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(.top, 6)
            }
            let units = store.userData.profile.units
            Text("\(plan.stops.count) trails · \(plan.liftRides) lift rides · \(Format.vert(plan.skiVerticalM, units)) skied · \(RouteSummary.duration(plan.finishTime.timeIntervalSince(plan.startTime)))")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
    }

    private func approach(_ s: DayPlan.Stop) -> String {
        let lifts = s.route.liftIDs.compactMap { store.lift($0)?.name }
        let trails = s.route.trailIDs.dropLast().compactMap { store.trail($0)?.name }
        var parts: [String] = []
        if !lifts.isEmpty { parts.append("Ride " + lifts.joined(separator: " → ")) }
        if !trails.isEmpty { parts.append("via " + trails.prefix(3).joined(separator: ", ") + (trails.count > 3 ? "…" : "")) }
        return (parts.isEmpty ? "Right here" : parts.joined(separator: ", ")) + " · \(RouteSummary.duration(s.route.seconds))"
    }

    private func timeRow<C: View>(_ time: String, symbol: String?, tint: Color, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(time).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 58, alignment: .trailing).padding(.top, 2)
            content().padding(.bottom, 10).padding(.leading, 22)
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .top) {
                Rectangle().fill(.secondary.opacity(0.3)).frame(width: 2).frame(maxHeight: .infinity)
                Circle().fill(tint).frame(width: 9, height: 9).padding(.top, 5)
            }
            .frame(width: 12)
            .padding(.leading, 68)
        }
    }
}

// MARK: - Send to phone

/// Renders the plan as a phone-sized image and offers the share sheet (AirDrop, Messages, Notes…).
private struct SendToPhoneButton: View {
    @Environment(AppStore.self) private var store
    let plan: DayPlan

    var body: some View {
        Menu {
            if let url = renderImage() {
                ShareLink(item: url, preview: SharePreview("SkiLo day plan", image: Image(systemName: "map"))) {
                    Label("Share Image (AirDrop, Messages…)", systemImage: "square.and.arrow.up")
                }
            }
            ShareLink(item: store.planText()) { Label("Share as Text", systemImage: "text.alignleft") }
            Divider()
            Button { saveImage() } label: { Label("Save Image…", systemImage: "square.and.arrow.down") }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.planText(), forType: .string)
                store.showToast(Toast(kind: .info, text: "Plan copied", symbol: "doc.on.doc", actions: []))
            } label: { Label("Copy as Text", systemImage: "doc.on.doc") }
        } label: {
            Label("Send to Phone", systemImage: "iphone.and.arrow.forward")
        }
        .fixedSize()
        .help("Take the plan up the mountain: AirDrop it, message it to yourself, or save it")
    }

    @MainActor private func renderImage() -> URL? {
        let renderer = ImageRenderer(content: PlanShareCard(plan: plan).environment(store))
        renderer.scale = 3
        guard let cg = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SkiLo Day Plan.png")
        do { try png.write(to: url, options: .atomic) } catch { return nil }
        return url
    }

    @MainActor private func saveImage() {
        guard let src = renderImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "SkiLo Day Plan.png"
        guard panel.runModal() == .OK, let dst = panel.url else { return }
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: src, to: dst)
    }
}

/// Phone-shaped card: 390 pt wide, light, readable on a lift.
struct PlanShareCard: View {
    @Environment(AppStore.self) private var store
    let plan: DayPlan

    var body: some View {
        let c = store.conditions
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SkiLo · \(store.resort.shortName)").font(.headline).foregroundStyle(.secondary)
                    Text(plan.startTime.formatted(.dateTime.weekday(.wide).month().day())).font(.title.weight(.bold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: c.kind.symbol).font(.title2)
                    Text(c.kind.title).font(.caption.weight(.semibold))
                }
            }
            if let d = store.planDayForecast {
                Text(String(format: "%.0f° / %.0f°C · %.0f cm new · gusts %.0f km/h", d.tempMaxC, d.tempMinC, c.freshCm, d.gustMaxKmh))
                    .font(.callout).foregroundStyle(.secondary)
            }
            PlanTimeline(plan: plan).allowsHitTesting(false)
            Text("Elo \(Elo.format(store.elo)) · routes: \(store.planner.difficulty.title.lowercased())").font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 390)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

// MARK: - Card

struct Card<Content: View, Trailing: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(title: String, symbol: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.symbol = symbol; self.trailing = trailing; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: symbol).font(.headline)
                Spacer()
                trailing()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6)))
    }
}
