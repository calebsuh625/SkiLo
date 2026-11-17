import SwiftUI

struct TrailInspector: View {
    @Environment(AppStore.self) private var store
    @State private var showOverride = false
    @State private var profileOpen = true
    @State private var whyOpen = true
    @State private var historyOpen = true
    @State private var notesOpen = true
    init() {}

    var body: some View {
        Group {
            if let id = store.selection, let trail = store.trail(id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(trail)
                        ratingBlock(trail)
                        statusControls(trail)
                        statsGrid(trail)
                        DisclosureGroup("Elevation profile", isExpanded: $profileOpen) {
                            ElevationProfileChart(trail: trail, units: store.userData.profile.units).padding(.top, 6)
                        }
                        DisclosureGroup("Why \(trail.rating.total)?", isExpanded: $whyOpen) { breakdown(trail).padding(.top, 6) }
                        DisclosureGroup("Your history", isExpanded: $historyOpen) { history(trail).padding(.top, 6) }
                        DisclosureGroup("Notes", isExpanded: $notesOpen) { NotesEditor(trailID: trail.id).id(trail.id).padding(.top, 6) }
                        Text("OSM ways \(trail.osmWayIDs.map(String.init).joined(separator: ", ")) · ODbL")
                            .font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                    .padding(16)
                }
                .onReceive(NotificationCenter.default.publisher(for: .htOverrideRating)) { _ in consumeOverrideRequest() }
                .onAppear { consumeOverrideRequest() }
            } else {
                ContentUnavailableView("No trail selected", systemImage: "mappin.slash",
                                       description: Text("Select a trail on the map or in a table."))
            }
        }
    }

    private func consumeOverrideRequest() {
        guard let p = OverrideCoordinator.pendingTrail, p == store.selection else { return }
        OverrideCoordinator.pendingTrail = nil
        showOverride = true
    }

    // MARK: header + rating

    private func header(_ t: Trail) -> some View {
        let rating = store.effectiveRating(t)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(t.name).font(.title2.weight(.bold)).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 8)
                BandSymbol(band: Band.of(rating)).font(.title3)
            }
            Text("\(t.area.title) · \(t.subArea.title)").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func ratingBlock(_ t: Trail) -> some View {
        let s = store.state(for: t.id)
        let rating = store.effectiveRating(t)
        return HStack(alignment: .top, spacing: 12) {
            RatingPill(rating: rating, isOverride: s.ratingOverride != nil, size: .largeTitle)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(rating) / 100").font(.headline.monospacedDigit())
                    Text(Band.of(rating).title).font(.headline).foregroundStyle(.secondary)
                }
                Text(osmLine(t)).font(.callout).foregroundStyle(.secondary)
                if let o = s.ratingOverride {
                    Label("your override: \(o)  (computed \(t.rating.total))", systemImage: "pencil").font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    ReadinessChip(readiness: store.readiness(for: t.id))
                    let worth = store.eloPreview(for: t.id)
                    Label("\(Elo.formatDelta(worth) ?? "+0.0") Elo", systemImage: "trophy.fill")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .help("Elo you'd gain for a clean run of this trail right now (your Elo \(Elo.format(store.elo)) vs. trail \(rating))")
                }
            }
        }
    }

    private func osmLine(_ t: Trail) -> String {
        var parts = ["OSM: \(t.osmDifficulty.rawValue)", t.grooming.title.lowercased()]
        if t.grooming == .unknown { parts.removeLast() }
        if t.gladed { parts.append("gladed") }
        return parts.joined(separator: " · ")
    }

    // MARK: status

    private func statusControls(_ t: Trail) -> some View {
        let binding = Binding<TrailStatus>(
            get: { store.state(for: t.id).status },
            set: { new in
                let s = store.state(for: t.id)
                guard new != s.status else { return }
                switch new {
                case .done: store.markDone(t.id)
                case .notDone:
                    if s.isDone { store.markNotDone(t.id) }
                    if store.state(for: t.id).bucketedAt != nil { store.removeFromBucket(t.id) }
                case .bucket:
                    if s.isDone { store.markNotDone(t.id) }
                    store.addToBucket([t.id])
                }
            })
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Status", selection: binding) {
                Text("Not done").tag(TrailStatus.notDone)
                Label("Bucket", systemImage: "star.fill").tag(TrailStatus.bucket)
                Label("Done", systemImage: "checkmark").tag(TrailStatus.done)
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack {
                if store.state(for: t.id).isDone {
                    Button { store.recordAnotherRun(t.id) } label: { Label("Ran It Again", systemImage: "arrow.clockwise") }
                        .help("Count another run of this trail (\(Elo.formatDelta(store.eloPreview(for: t.id)) ?? "+0.0") Elo) — ⌘R")
                }
                Button { store.requestLogRun(trailID: t.id) } label: { Label("Log Run…", systemImage: "plus.circle") }
                Button { store.showOnMap(t.id) } label: { Label("Show on Map", systemImage: "map") }
            }
            .controlSize(.regular)
            HStack {
                Button { store.openDirections(to: .trail(t.id)) } label: { Label("Directions Here", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                    .help("Route from a lodge or lift to the top of this trail (⌘G)")
                Button { store.flyThrough(trail: t.id) } label: { Label("Fly Through", systemImage: "play.fill") }
                    .help("Fly down this trail on the 3D map (⌥⌘P)")
            }
            .controlSize(.regular)
        }
    }

    // MARK: stats

    private func statsGrid(_ t: Trail) -> some View {
        let u = store.userData.profile.units, s = t.stats
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow { stat("Length", Format.length(s.lengthM, u)); stat("Vert", Format.vert(s.verticalDropM, u)) }
            GridRow { stat("Avg", Format.grade(s.avgGradePct)); stat("Max", Format.grade(s.maxGradePct)) }
            GridRow { stat("Top", Format.elevation(s.topElevM, u)); stat("Bottom", Format.elevation(s.bottomElevM, u)) }
        }
    }
    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(value).font(.callout.monospacedDigit())
        }
    }

    // MARK: breakdown

    private func breakdown(_ t: Trail) -> some View {
        let s = store.state(for: t.id)
        return VStack(alignment: .leading, spacing: 10) {
            RatingBreakdownView(breakdown: t.rating, override: s.ratingOverride, note: s.ratingOverrideNote)
            HStack {
                Button("Override rating…") { showOverride = true }
                    .popover(isPresented: $showOverride, arrowEdge: .bottom) { OverridePopover(trailID: t.id, isPresented: $showOverride).environment(store) }
                if s.ratingOverride != nil { Button("Reset") { store.setOverride(t.id, rating: nil, note: nil) } }
            }
        }
    }

    // MARK: history

    private func skiedLine(_ s: UserTrailState, runs: Int) -> String {
        var line = "Skied \(max(s.timesSkied, runs))×"
        if let d = s.firstDoneDate { line += " · first \(Format.date(d))" }
        return line
    }

    @ViewBuilder private func history(_ t: Trail) -> some View {
        let s = store.state(for: t.id)
        let runs = store.userData.runLog.filter { $0.trailID == t.id }.sorted { $0.date > $1.date }
        VStack(alignment: .leading, spacing: 6) {
            if s.timesSkied == 0 && runs.isEmpty {
                Text("Not skied yet").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(skiedLine(s, runs: runs.count)).font(.callout)
                if s.backfilled { Text("Backfilled during setup").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(runs.prefix(5)) { r in
                HStack(spacing: 8) {
                    Text(Format.date(r.date)).font(.callout.monospacedDigit())
                    Text(r.conditions.label.lowercased()).font(.callout).foregroundStyle(.secondary)
                    Text(String(repeating: "★", count: r.confidence) + String(repeating: "☆", count: max(0, 5 - r.confidence)))
                        .font(.caption).foregroundStyle(.orange)
                    if !r.notes.isEmpty { Text("“\(r.notes)”").font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            if !runs.isEmpty {
                Button("Show all in Log →") { store.section = .log }.buttonStyle(.link).font(.callout)
            }
        }
    }
}

/// Plain-text notes with a 600 ms debounced autosave (also flushed when the view goes away).
struct NotesEditor: View {
    @Environment(AppStore.self) private var store
    let trailID: Trail.ID
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        TextEditor(text: $text)
            .font(.body).frame(minHeight: 80)
            .scrollContentBackground(.hidden).padding(6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            .onAppear { if !loaded { loaded = true; text = store.state(for: trailID).notes } }
            .task(id: text) {
                guard loaded else { return }
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled { commit() }
            }
            .onDisappear { commit() }
    }

    private func commit() {
        guard loaded, store.state(for: trailID).notes != text else { return }
        store.setNotes(trailID, text)
    }
}
