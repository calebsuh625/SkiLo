import SwiftUI

/// UX_SPEC §4. Manual order lives in `UserData.bucketOrder`; Sort is a view-only transformation.
struct BucketScreen: View {
    @Environment(AppStore.self) private var store
    @State private var sort: Sort = .manual
    @State private var showCrossed = true
    @State private var showAdd = false

    enum Sort: String, CaseIterable, Identifiable {
        case manual = "Manual", rating = "Rating", area = "Area"
        var id: String { rawValue }
    }

    private var pending: [Trail.ID] { store.bucketPending.filter { store.trail($0) != nil } }
    private var crossed: [Trail.ID] { store.bucketCrossedOff }
    private var displayed: [Trail.ID] {
        switch sort {
        case .manual: return pending
        case .rating: return pending.sorted { store.effectiveRating($0) < store.effectiveRating($1) }
        case .area: return pending.sorted {
            let a = store.trail($0)!, b = store.trail($1)!
            return (a.area.rawValue, a.subArea.title, store.effectiveRating(a)) < (b.area.rawValue, b.subArea.title, store.effectiveRating(b))
        }
        }
    }

    var body: some View {
        Group {
            if pending.isEmpty && crossed.isEmpty { emptyState } else { list }
        }
        .navigationTitle("Bucket List")
        .toolbar {
            ToolbarItemGroup {
                Button { showAdd = true } label: { Label("Add Trail…", systemImage: "plus") }
                    .popover(isPresented: $showAdd, arrowEdge: .bottom) { AddTrailPopover(isPresented: $showAdd) }
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                Toggle(isOn: $showCrossed) { Label("Show crossed-off", systemImage: "checkmark.circle") }
            }
        }
    }

    // MARK: list

    private var list: some View {
        List {
            Section { header.listRowSeparator(.hidden) }
            if !pending.isEmpty {
                Section("To ski") {
                    ForEach(Array(displayed.enumerated()), id: \.element) { idx, id in
                        PendingRow(id: id, rank: idx + 1, manual: sort == .manual, isFirst: idx == 0)
                    }
                    .onMove { from, to in if sort == .manual { store.moveBucket(from: from, to: to) } }
                }
            }
            if showCrossed && !crossed.isEmpty {
                Section("Crossed off") {
                    ForEach(crossed, id: \.self) { CrossedRow(id: $0) }
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: pending)
    }

    private var header: some View {
        let total = pending.count + crossed.count
        let frac = total == 0 ? 0 : Double(crossed.count) / Double(total)
        let ids = pending + crossed
        let avg = ids.isEmpty ? 1 : ids.map { store.effectiveRating($0) }.reduce(0, +) / ids.count
        let vert = pending.compactMap { store.trail($0)?.stats.verticalDropM }.reduce(0, +)
        return HStack(alignment: .center, spacing: 20) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 9)
                Circle().trim(from: 0, to: frac).stroke(Ramp.swiftUIColor(for: avg), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(crossed.count)/\(total)").font(.title3.weight(.bold)).monospacedDigit()
                    Text("\(Int((frac * 100).rounded()))%").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 92, height: 92)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(crossed.count) of \(total) crossed off")
            VStack(alignment: .leading, spacing: 8) {
                Text("Bucket List").font(.title2.weight(.semibold))
                Text("\(crossed.count) crossed off · \(pending.count) to go · \(Format.vert(vert, store.userData.profile.units)) of vert waiting")
                    .foregroundStyle(.secondary)
                suggestedCard
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var suggestedCard: some View {
        let s = store.progression.suggestedNext(bucket: store.userData.bucketOrder, trails: store.trailsByID,
                                                ratings: store.effectiveRatings, states: store.userData.trailStates, skill: store.skill)
        if let s, let t = store.trail(s.id) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill").foregroundStyle(Ramp.bucketYellow.color)
                Text("Suggested next:").foregroundStyle(.secondary)
                Text(t.name).fontWeight(.semibold)
                RatingPill(rating: store.effectiveRating(t), size: .caption)
                Text("— \(s.reason)").foregroundStyle(.secondary).lineLimit(1)
                Button("Show ▸") { store.showOnMap(t.id) }.buttonStyle(.link)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var emptyState: some View {
        let ready = store.progression.readyFor(trails: store.catalog.trails, ratings: store.effectiveRatings,
                                               states: store.userData.trailStates, skill: store.skill, limit: 5)
        return VStack(spacing: 14) {
            Image(systemName: "star").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Your bucket list is empty").font(.title3.weight(.semibold))
            Text("Star trails on the map or in Trails, or try these:").foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(ready, id: \.self) { id in
                    if let t = store.trail(id) {
                        HStack {
                            BandSymbol(band: Band.of(store.effectiveRating(t)))
                            Text(t.name).fontWeight(.medium)
                            RatingPill(rating: store.effectiveRating(t), size: .caption)
                            Spacer()
                            Button("Add") { store.addToBucket([id]) }
                        }
                    }
                }
            }
            .frame(maxWidth: 380)
            if !ready.isEmpty { Button("Add all \(ready.count)") { store.addToBucket(ready) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private func areaLine(_ t: Trail) -> String {
    t.grooming == .moguls ? "\(t.area.rawValue) · moguls" : t.gladed ? "\(t.area.rawValue) · glades" : t.area.rawValue
}

private struct PendingRow: View {
    @Environment(AppStore.self) private var store
    let id: Trail.ID; let rank: Int; let manual: Bool; let isFirst: Bool
    var body: some View {
        if let t = store.trail(id) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").foregroundStyle(manual ? .tertiary : .quaternary).help(manual ? "Drag to reorder" : "Switch Sort to Manual to reorder")
                Text("\(rank)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                Image(systemName: "star.fill").foregroundStyle(Ramp.bucketYellow.color)
                Text(t.name).fontWeight(.medium)
                Spacer(minLength: 8)
                BandSymbol(band: Band.of(store.effectiveRating(t)))
                RatingPill(rating: store.effectiveRating(t), isOverride: store.state(for: id).ratingOverride != nil, size: .callout)
                Text(areaLine(t)).font(.callout).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                ReadinessChip(readiness: store.readiness(for: id)).frame(width: 130, alignment: .leading)
                Button { withAnimation(.easeInOut(duration: 0.3)) { store.markDone(id) } } label: { Label("Done", systemImage: "checkmark") }
                    .buttonStyle(.bordered).controlSize(.small)
                Menu {
                    Button("Show on Map") { store.showOnMap(id) }
                    Button("Log Run…") { store.requestLogRun(trailID: id) }
                    Button("Move to top") { if let i = store.userData.bucketOrder.firstIndex(of: id) { store.moveBucket(from: IndexSet(integer: i), to: 0) } }
                    Divider()
                    Button("Remove from list", role: .destructive) { store.removeFromBucket(id) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 28)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { store.select(id, showInspector: true) }
        }
    }
}

private struct CrossedRow: View {
    @Environment(AppStore.self) private var store
    let id: Trail.ID
    var body: some View {
        if let t = store.trail(id) {
            let s = store.state(for: id)
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Ramp.doneGreen.color).frame(width: 22)
                Text(t.name).strikethrough().foregroundStyle(.secondary)
                Spacer()
                BandSymbol(band: Band.of(store.effectiveRating(t)))
                RatingPill(rating: store.effectiveRating(t), size: .callout)
                Text(t.area.rawValue).font(.callout).foregroundStyle(.secondary).frame(width: 36)
                Text("done " + (s.lastDoneDate.map(Format.date) ?? "")).font(.callout).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                Menu {
                    Button("Show on Map") { store.showOnMap(id) }
                    Button("Log Run…") { store.requestLogRun(trailID: id) }
                    Button("Mark not done") { store.markNotDone(id) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 28)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture { store.select(id, showInspector: true) }
        }
    }
}
