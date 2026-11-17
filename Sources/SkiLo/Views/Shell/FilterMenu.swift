import SwiftUI

/// Shared filter control used by the Map / Trails / Bucket toolbars (and the View > Filters menu).
struct FilterMenu: View {
    @Environment(AppStore.self) private var store
    init() {}
    var body: some View {
        Menu {
            FilterMenuContent(store: store)
        } label: {
            Label("Filter", systemImage: store.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help(store.filter.isActive ? "Filters active" : "Filter trails")
    }
}

/// Menu items; reusable inside `Commands`, where the SwiftUI environment is unavailable.
struct FilterMenuContent: View {
    let store: AppStore
    init(store: AppStore) { self.store = store }

    private func toggle<T: Hashable>(_ keyPath: WritableKeyPath<TrailFilter, Set<T>>, _ value: T) -> Binding<Bool> {
        Binding(get: { store.filter[keyPath: keyPath].contains(value) },
                set: { on in if on { store.filter[keyPath: keyPath].insert(value) } else { store.filter[keyPath: keyPath].remove(value) } })
    }
    private func groomingBinding(_ g: Grooming) -> Binding<Bool> {
        Binding(get: { store.filter.grooming?.contains(g) ?? true },
                set: { on in
                    var s = store.filter.grooming ?? Set(Grooming.allCases)
                    if on { s.insert(g) } else { s.remove(g) }
                    store.filter.grooming = s.count == Grooming.allCases.count ? nil : s
                })
    }

    var body: some View {
        Section("Area") {
            ForEach(Area.allCases, id: \.self) { Toggle($0.title, isOn: toggle(\.areas, $0)) }
        }
        Section("Status") {
            Toggle("Not done", isOn: toggle(\.statuses, .notDone))
            Toggle("Bucket list", isOn: toggle(\.statuses, .bucket))
            Toggle("Done", isOn: toggle(\.statuses, .done))
        }
        Section("Difficulty") {
            Button("All ratings") { store.filter.ratingRange = 1...100 }
            ForEach(Band.allCases, id: \.self) { band in
                Button("\(band.title)  \(band.range.lowerBound)–\(band.range.upperBound)") { store.filter.ratingRange = band.range }
            }
            Button("Black and up  50–100") { store.filter.ratingRange = 50...100 }
        }
        Section("Terrain") {
            ForEach([Grooming.groomed, .moguls, .backcountry], id: \.self) { Toggle($0.title, isOn: groomingBinding($0)) }
            Toggle("Gladed only", isOn: Binding(get: { store.filter.gladedOnly }, set: { store.filter.gladedOnly = $0 }))
            Toggle("Ready for me", isOn: Binding(get: { store.filter.readyForMe }, set: { store.filter.readyForMe = $0 }))
        }
        Divider()
        Button("Clear Filters") {
            let q = store.filter.searchText
            store.filter = TrailFilter(searchText: q)
        }.disabled(!store.filter.isActive)
    }
}

extension TrailFilter {
    /// Short human description for the Trails status bar, e.g. "NV, 50–100, done". Empty when inactive.
    var summary: String {
        var parts: [String] = []
        if areas.count < Area.allCases.count { parts.append(Area.allCases.filter { areas.contains($0) }.map(\.rawValue).joined(separator: "+")) }
        if ratingRange != 1...100 { parts.append("\(ratingRange.lowerBound)–\(ratingRange.upperBound)") }
        if statuses.count < TrailStatus.allCases.count {
            parts.append(TrailStatus.allCases.filter { statuses.contains($0) }.map { $0 == .notDone ? "not done" : $0 == .bucket ? "bucket" : "done" }.joined(separator: "+"))
        }
        if let g = grooming { parts.append(g.map(\.title).sorted().joined(separator: "+").lowercased()) }
        if let s = subAreas { parts.append("\(s.count) sub-areas") }
        if gladedOnly { parts.append("gladed") }
        if readyForMe { parts.append("ready for me") }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { parts.append("“\(q)”") }
        return parts.joined(separator: ", ")
    }
}
