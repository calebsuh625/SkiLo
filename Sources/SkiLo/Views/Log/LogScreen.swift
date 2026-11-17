import SwiftUI

/// UX_SPEC §6.1. Day sections (newest first) derived from `store.skiDays`.
struct LogScreen: View {
    @Environment(AppStore.self) private var store
    @State private var dayFilter: String? = nil
    @State private var selection: Set<UUID> = []
    @State private var editDayKey: String?

    private var days: [SkiDay] {
        let q = store.filter.searchText.trimmingCharacters(in: .whitespaces)
        return store.skiDays.compactMap { day in
            if let f = dayFilter, f != day.id { return nil }
            guard !q.isEmpty else { return day }
            var d = day
            d.entries = day.entries.filter { e in
                (store.trail(e.trailID)?.name.localizedCaseInsensitiveContains(q) ?? false) || e.notes.localizedCaseInsensitiveContains(q)
            }
            return d.entries.isEmpty ? nil : d
        }
    }

    var body: some View {
        Group {
            if store.userData.runLog.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "book.closed").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No runs logged yet").font(.title3.weight(.semibold))
                    Text("Log a run to start your ski days and build your skill estimate.").foregroundStyle(.secondary)
                    Button("Log Run…") { store.requestLogRun(trailID: nil) }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(days) { day in
                        Section { ForEach(day.entries) { RunRow(entry: $0, selection: $selection) } } header: { DayHeader(day: day) { editDayKey = day.id } }
                    }
                }
                .onDeleteCommand { for id in selection { store.deleteRun(id) }; selection = [] }
            }
        }
        .navigationTitle("Log")
        .toolbar {
            ToolbarItemGroup {
                Button { store.requestLogRun(trailID: nil) } label: { Label("Log Run…", systemImage: "plus") }
                Menu(dayFilter == nil ? "All days" : "One day") {
                    Button("All days") { dayFilter = nil }
                    ForEach(store.skiDays) { d in Button(Format.date(d.date)) { dayFilter = d.id } }
                }
            }
        }
        .sheet(isPresented: Binding(get: { editDayKey != nil }, set: { if !$0 { editDayKey = nil } })) {
            if let k = editDayKey { EditDaySheet(dayKey: k, isPresented: Binding(get: { editDayKey != nil }, set: { if !$0 { editDayKey = nil } })) }
        }
    }
}

private struct DayHeader: View {
    @Environment(AppStore.self) private var store
    let day: SkiDay; let edit: () -> Void
    var body: some View {
        let vert = day.entries.compactMap { store.trail($0.trailID)?.stats.verticalDropM }.reduce(0, +)
        let top = day.entries.map { store.effectiveRating($0.trailID) }.max() ?? 0
        HStack(spacing: 6) {
            Text(day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())).font(.headline)
            if let t = day.meta?.title, !t.isEmpty { Text("· “\(t)”").font(.headline).foregroundStyle(.secondary) }
            if let c = day.meta?.conditions { Text("· \(c.label.lowercased())").foregroundStyle(.secondary) }
            Text("· \(day.entries.count) run\(day.entries.count == 1 ? "" : "s") · \(Format.vert(vert, store.userData.profile.units)) · top \(top)")
                .foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button("Edit day", action: edit).controlSize(.small)
        }
        .textCase(nil)
        .padding(.vertical, 2)
    }
}

private struct RunRow: View {
    @Environment(AppStore.self) private var store
    let entry: RunLogEntry
    @Binding var selection: Set<UUID>
    var body: some View {
        let t = store.trail(entry.trailID)
        let rating = store.effectiveRating(entry.trailID)
        HStack(spacing: 10) {
            Text(Format.time(entry.date)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Button { store.select(entry.trailID, showInspector: true) } label: {
                Text(t?.name ?? entry.trailID).fontWeight(.medium)
            }.buttonStyle(.link).frame(width: 170, alignment: .leading)
            BandSymbol(band: Band.of(rating))
            RatingPill(rating: rating, size: .callout)
            Text("× " + String(format: "%.2f", entry.conditions.multiplier) + " " + entry.conditions.label.lowercased())
                .font(.callout).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { Image(systemName: $0 <= entry.confidence ? "star.fill" : "star").font(.caption) }
            }.foregroundStyle(.orange).accessibilityLabel("Confidence \(entry.confidence) of 5")
            if !entry.notes.isEmpty { Text("“\(entry.notes)”").font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
            Spacer(minLength: 4)
            if entry.isFirstTime {
                Text("NEW").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Ramp.doneGreen.color.opacity(0.2), in: Capsule()).foregroundStyle(Ramp.doneGreen.color)
            }
        }
        .tag(entry.id)
        .contextMenu {
            Button("Edit…") { store.logRunRequest = LogRunRequest(trailID: entry.trailID, date: entry.date, existing: entry) }
            Button("Duplicate") {
                var c = entry; c.id = UUID(); c.date = .now; c.isFirstTime = false
                store.logRun(c, alsoMarkDone: false)
            }
            Button("Show on Map") { store.showOnMap(entry.trailID) }
            Divider()
            Button("Delete", role: .destructive) { store.deleteRun(entry.id) }
        }
    }
}
