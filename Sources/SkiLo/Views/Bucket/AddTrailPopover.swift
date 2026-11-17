import SwiftUI

/// UX_SPEC §4: search + multi-select of not-bucketed, not-done trails; "Add" commits.
struct AddTrailPopover: View {
    @Environment(AppStore.self) private var store
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var picked: Set<Trail.ID> = []

    init(isPresented: Binding<Bool>) { self._isPresented = isPresented }

    private var candidates: [Trail] {
        store.catalog.trails.filter { t in
            let s = store.state(for: t.id)
            guard s.bucketedAt == nil, !s.isDone else { return false }
            let q = query.trimmingCharacters(in: .whitespaces)
            return q.isEmpty || t.name.localizedCaseInsensitiveContains(q)
        }
        .sorted { store.effectiveRating($0) != store.effectiveRating($1) ? store.effectiveRating($0) < store.effectiveRating($1) : $0.name < $1.name }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search trails", text: $query).textFieldStyle(.roundedBorder)
            List(candidates, id: \.id) { t in
                let on = picked.contains(t.id)
                Button {
                    if on { picked.remove(t.id) } else { picked.insert(t.id) }
                } label: {
                    HStack {
                        Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? Color.accentColor : .secondary)
                        Text(t.name)
                        Spacer()
                        BandSymbol(band: Band.of(store.effectiveRating(t)))
                        RatingPill(rating: store.effectiveRating(t), size: .caption)
                        ReadinessChip(readiness: store.readiness(for: t.id))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .overlay { if candidates.isEmpty { Text("No matching trails").foregroundStyle(.secondary) } }
            HStack {
                Text("\(picked.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Add") { store.addToBucket(candidates.map(\.id).filter(picked.contains)); isPresented = false }
                    .keyboardShortcut(.defaultAction).disabled(picked.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 460, height: 400)
    }
}
