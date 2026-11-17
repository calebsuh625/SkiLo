import SwiftUI
import AppKit

struct TrailsScreen: View {
    @Environment(AppStore.self) private var store
    @AppStorage("trails.columns") private var columnsJSON: String = TrailColumn.encode(TrailColumn.defaultVisible)
    @AppStorage("trails.group") private var groupRaw: String = TrailGrouping.none.rawValue
    @State private var sortOrder: [KeyPathComparator<TrailRow>] = [TrailColumn.name.comparator]
    @State private var selected: Set<Trail.ID> = []
    init() {}

    private var columns: [TrailColumn] { TrailColumn.decode(columnsJSON) }
    private var grouping: TrailGrouping { TrailGrouping(rawValue: groupRaw) ?? .none }

    var body: some View {
        let rows = TrailRow.rows(for: store.visibleTrails, store: store).sorted(using: sortOrder)
        VStack(spacing: 0) {
            statusBar(rows)
            Divider()
            if rows.isEmpty {
                ContentUnavailableView("No trails match", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Adjust or clear the filters."))
            } else if grouping == .none {
                table(rows)
            } else {
                GroupedTrailsList(rows: rows, grouping: grouping, selected: $selected, store: store)
            }
        }
        .toolbar { toolbar }
        .navigationTitle("Trails")
        .onChange(of: selected) { _, new in syncSelectionToStore(new) }
        .onChange(of: store.selection) { _, new in
            if let new { if selected != [new] && !selected.contains(new) { selected = [new] } } else if selected.count <= 1 { selected = [] }
        }
        .onAppear {
            if let s = store.selection { selected = [s] }
            // Dev hook (headless screenshots): HT_TRAILS_SORT=rating|rating-desc|name
            if let k = DevHooks.env["HT_TRAILS_SORT"] {
                let key = k.replacingOccurrences(of: "-desc", with: "")
                if let col = TrailColumn(rawValue: key) {
                    var c = col.comparator; if k.hasSuffix("-desc") { c.order = .reverse }
                    sortOrder = [c]
                }
            }
        }
    }

    // MARK: table (grouping == none)

    private func table(_ rows: [TrailRow]) -> some View {
        Table(rows, selection: $selected, sortOrder: $sortOrder) {
            TableColumnForEach(columns) { col in
                TableColumn(col.title, sortUsing: col.comparator) { row in
                    TrailCell(column: col, row: row, units: store.userData.profile.units)
                }
                .width(min: col.width.lowerBound, ideal: col.width.lowerBound + (col == .name ? 40 : 6), max: col.width.upperBound)
            }
        }
        .contextMenu(forSelectionType: Trail.ID.self) { ids in
            TrailContextMenu(ids: ids, store: store)
        } primaryAction: { ids in
            if let id = ids.first { store.select(id, showInspector: true) }
        }
    }

    // MARK: status bar

    private func statusBar(_ rows: [TrailRow]) -> some View {
        let total = store.catalog.trails.count
        let done = rows.filter { $0.status == .done }.count
        let bucket = rows.filter { $0.status == .bucket }.count
        var text = rows.count == total ? "\(total) trails" : "\(rows.count) of \(total) trails"
        text += " · \(done) done · \(bucket) bucketed"
        let f = store.filter.summary
        if !f.isEmpty { text += " · filter: \(f)" }
        if selected.count > 1 { text += " · \(selected.count) selected" }
        return HStack {
            Text(text).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: selection sync

    private func syncSelectionToStore(_ new: Set<Trail.ID>) {
        if new.count == 1, let id = new.first { if store.selection != id { store.select(id, showInspector: false) } }
        else if new.isEmpty { if store.selection != nil { store.select(nil, showInspector: false) } }
        else if let cur = store.selection, new.contains(cur) { /* keep */ }
        else { store.select(new.sorted().first, showInspector: false) }
    }

    // MARK: toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            FilterMenu()
            Menu {
                Picker("Group by", selection: $groupRaw) {
                    ForEach(TrailGrouping.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.inline)
            } label: { Label("Group: \(grouping.title)", systemImage: "rectangle.3.group") }
            Menu {
                ForEach(TrailColumn.allCases.filter { $0 != .name }) { col in
                    Toggle(col.menuTitle, isOn: Binding(
                        get: { columns.contains(col) },
                        set: { on in
                            var c = columns
                            if on { if !c.contains(col) { c.append(col) } } else { c.removeAll { $0 == col } }
                            columnsJSON = TrailColumn.encode(c)
                        }))
                }
                Divider()
                Button("Reset Columns") { columnsJSON = TrailColumn.encode(TrailColumn.defaultVisible) }
            } label: { Label("Columns", systemImage: "tablecells") }
        }
        ToolbarItemGroup(placement: .secondaryAction) {
            let ids = Array(selected)
            let allDone = !ids.isEmpty && ids.allSatisfy { store.state(for: $0).isDone }
            let allBucket = !ids.isEmpty && ids.allSatisfy { store.state(for: $0).bucketedAt != nil }
            Button {
                if allDone { ids.forEach { store.markNotDone($0) } } else { store.markDone(ids.filter { !store.state(for: $0).isDone }, backfilled: false) }
            } label: { Label(allDone ? "Mark Not Done" : "Mark Done", systemImage: allDone ? "arrow.uturn.backward.circle" : "checkmark.circle") }
                .disabled(ids.isEmpty)
            Button {
                if allBucket { ids.forEach { store.removeFromBucket($0) } } else { store.addToBucket(ids) }
            } label: { Label(allBucket ? "Remove from Bucket" : "Bucket", systemImage: allBucket ? "star.slash" : "star") }
                .disabled(ids.isEmpty)
        }
    }
}

// MARK: - cells

struct TrailCell: View {
    let column: TrailColumn; let row: TrailRow; let units: Units
    var body: some View {
        let t = row.trail, s = t.stats
        switch column {
        case .status: StatusGlyph(status: row.status)
        case .name: Text(t.name).lineLimit(1)
        case .area: Text(t.area.rawValue).help(t.subArea.title)
        case .rating: RatingPill(rating: row.rating, isOverride: row.isOverride, size: .caption)
        case .band: BandSymbol(band: row.band)
        case .osm:
            if let b = t.osmDifficulty.band { BandSymbol(band: b) } else { Text("—").foregroundStyle(.tertiary) }
        case .length: Text(Format.length(s.lengthM, units)).monospacedDigit()
        case .vert: Text(Format.vert(s.verticalDropM, units)).monospacedDigit()
        case .avgGrade: Text(Format.grade(s.avgGradePct)).monospacedDigit()
        case .maxGrade: Text(Format.grade(s.maxGradePct)).monospacedDigit()
        case .grooming: Text(t.grooming.title).foregroundStyle(t.grooming == .unknown ? .tertiary : .primary)
        case .gladed: if t.gladed { Image(systemName: "tree.fill").foregroundStyle(.green) } else { Text("") }
        case .lift: Text(t.liftName ?? "—").lineLimit(1).foregroundStyle(t.liftName == nil ? .tertiary : .primary)
        case .times: Text(row.timesSkied == 0 ? "" : "\(row.timesSkied)").monospacedDigit()
        case .firstDone: Text(row.firstDone.map(Format.date) ?? "")
        case .topElev: Text(Format.elevation(s.topElevM, units)).monospacedDigit()
        case .bottomElev: Text(Format.elevation(s.bottomElevM, units)).monospacedDigit()
        }
    }
}

// MARK: - context menu

struct TrailContextMenu: View {
    let ids: Set<Trail.ID>; let store: AppStore
    var body: some View {
        if let first = ids.sorted().first {
            let allDone = ids.allSatisfy { store.state(for: $0).isDone }
            let allBucket = ids.allSatisfy { store.state(for: $0).bucketedAt != nil }
            Button(allDone ? "Mark Not Done" : "Mark Done") {
                if allDone { ids.forEach { store.markNotDone($0) } } else { store.markDone(ids.filter { !store.state(for: $0).isDone }.sorted(), backfilled: false) }
            }
            Button(allBucket ? "Remove from Bucket List" : "Add to Bucket List") {
                if allBucket { ids.forEach { store.removeFromBucket($0) } } else { store.addToBucket(ids.sorted()) }
            }
            Button("Log Run…") { store.requestLogRun(trailID: first) }
            Divider()
            if ids.count == 1 {
                Button("Show on Map") { store.showOnMap(first) }
                Button("Override Rating…") { OverrideCoordinator.request(for: first, store: store) }
                Button("Copy Name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.trail(first)?.name ?? "", forType: .string)
                }
            }
        }
    }
}

// MARK: - grouped fallback (List with section headers)

struct GroupedTrailsList: View {
    let rows: [TrailRow]; let grouping: TrailGrouping
    @Binding var selected: Set<Trail.ID>
    let store: AppStore

    private struct Group: Identifiable { let id: String; let title: String; let rows: [TrailRow] }

    private var groups: [Group] {
        switch grouping {
        case .none: return [Group(id: "all", title: "All", rows: rows)]
        case .area:
            return Area.allCases.compactMap { a in
                let r = rows.filter { $0.trail.area == a }; return r.isEmpty ? nil : Group(id: a.rawValue, title: a.title, rows: r)
            }
        case .band:
            return Band.allCases.reversed().compactMap { b in
                let r = rows.filter { $0.band == b }; return r.isEmpty ? nil : Group(id: "\(b.rawValue)", title: b.title, rows: r)
            }
        }
    }

    var body: some View {
        List(selection: $selected) {
            ForEach(groups) { g in
                Section {
                    ForEach(g.rows) { row in
                        HStack(spacing: 10) {
                            StatusGlyph(status: row.status).frame(width: 18)
                            Text(row.trail.name).lineLimit(1)
                            Spacer()
                            BandSymbol(band: row.band)
                            RatingPill(rating: row.rating, isOverride: row.isOverride, size: .caption)
                            Text(Format.length(row.length, store.userData.profile.units)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                            Text(Format.vert(row.vert, store.userData.profile.units)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                        }
                        .tag(row.id)
                    }
                } header: {
                    let done = g.rows.filter { $0.status == .done }.count
                    Text("\(g.title) · \(g.rows.count) · \(done) done")
                }
            }
        }
        .contextMenu(forSelectionType: Trail.ID.self) { ids in
            TrailContextMenu(ids: ids, store: store)
        } primaryAction: { ids in
            if let id = ids.first { store.select(id, showInspector: true) }
        }
    }
}
