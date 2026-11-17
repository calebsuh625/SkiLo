import SwiftUI

/// All trails, hardest-first by default, with search, a status filter and swipe actions.
struct PhoneTrailsView: View {
    enum Show: String, CaseIterable, Identifiable { case all = "All", todo = "To do", done = "Done"; var id: Self { self } }
    enum Sort: String, CaseIterable, Identifiable { case rating = "Difficulty", name = "Name", ready = "Ready for me"; var id: Self { self } }
    @Environment(AppStore.self) private var store
    @State private var search = ""
    @State private var show: Show = .all
    @State private var sort: Sort = .rating
    @State private var path: [Trail.ID] = []

    private var rows: [Trail] {
        var ts = store.catalog.trails.filter { t in
            let s = store.state(for: t.id)
            switch show { case .all: break; case .todo: if s.isDone { return false }; case .done: if !s.isDone { return false } }
            return search.isEmpty || t.name.localizedCaseInsensitiveContains(search)
        }
        switch sort {
        case .rating: ts.sort { store.effectiveRating($0) > store.effectiveRating($1) }
        case .name: ts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .ready:
            ts = ts.filter { store.readiness(for: $0.id).kind == .ready }
            ts.sort { store.effectiveRating($0) > store.effectiveRating($1) }
        }
        return ts
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Picker("Show", selection: $show) { ForEach(Show.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                ForEach(rows) { t in
                    NavigationLink(value: t.id) { PhoneTrailRow(trail: t) }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) { doneSwipe(t.id) }
                        .swipeActions(edge: .trailing) { bucketSwipe(t.id) }
                }
                if rows.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Trails")
            .searchable(text: $search, prompt: "Search trails")
            .toolbar {
                Menu {
                    Picker("Sort", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            }
            .navigationDestination(for: Trail.ID.self) { PhoneTrailDetail(trailID: $0) }
        }
    }

    @ViewBuilder private func doneSwipe(_ id: Trail.ID) -> some View {
        if store.state(for: id).isDone {
            Button { store.recordAnotherRun(id) } label: { Label("Ran again", systemImage: "arrow.clockwise") }.tint(.green)
        } else {
            Button { store.markDone(id) } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
        }
    }
    @ViewBuilder private func bucketSwipe(_ id: Trail.ID) -> some View {
        let bucketed = store.state(for: id).bucketedAt != nil
        Button { store.toggleBucket(id) } label: { Label(bucketed ? "Unbucket" : "Bucket", systemImage: bucketed ? "star.slash" : "star") }
            .tint(.yellow)
        if store.state(for: id).isDone {
            Button(role: .destructive) { store.markNotDone(id) } label: { Label("Not done", systemImage: "arrow.uturn.backward") }
        }
    }
}

struct PhoneTrailRow: View {
    @Environment(AppStore.self) private var store
    let trail: Trail
    var body: some View {
        let s = store.state(for: trail.id)
        HStack(spacing: 12) {
            RatingPill(rating: store.effectiveRating(trail), isOverride: s.ratingOverride != nil, size: .headline)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(trail.name).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    BandSymbol(band: Band.of(store.effectiveRating(trail)))
                    Text(trail.placeLine).lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if s.timesSkied > 1 { Text("×\(s.timesSkied)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            StatusGlyph(status: s.status)
        }
        .padding(.vertical, 2)
    }
}
