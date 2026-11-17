import SwiftUI

struct PhoneBucketView: View {
    @Environment(AppStore.self) private var store
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                if let next = store.progression.suggestedNext(bucket: store.bucketPending, trails: store.trailsByID, ratings: store.effectiveRatings,
                                                              states: store.userData.trailStates, skill: store.skill),
                   let t = store.trail(next.id) {
                    Section("Up next") {
                        NavigationLink(value: t.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                PhoneTrailRow(trail: t)
                                Text(next.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("To do") {
                    if store.bucketPending.isEmpty {
                        Text("Add trails you want to ski. Swipe left on any trail, or tap +.").foregroundStyle(.secondary)
                    }
                    ForEach(store.bucketPending.compactMap { store.trail($0) }) { t in
                        NavigationLink(value: t.id) { PhoneTrailRow(trail: t) }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button { withAnimation { store.markDone(t.id) } } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { store.removeFromBucket(t.id) } label: { Label("Remove", systemImage: "star.slash") }
                            }
                    }
                    .onMove { store.moveBucket(from: $0, to: $1) }
                }
                if !store.bucketCrossedOff.isEmpty {
                    Section("Crossed off") {
                        ForEach(store.bucketCrossedOff.compactMap { store.trail($0) }) { t in
                            NavigationLink(value: t.id) { PhoneTrailRow(trail: t) }
                        }
                    }
                }
            }
            .navigationTitle("Bucket List")
            .navigationDestination(for: Trail.ID.self) { PhoneTrailDetail(trailID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") } }
            }
            .sheet(isPresented: $adding) { PhoneAddToBucket() }
        }
    }
}

private struct PhoneAddToBucket: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List(store.catalog.trails
                .filter { store.state(for: $0.id).bucketedAt == nil && !store.state(for: $0.id).isDone }
                .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                .sorted { store.effectiveRating($0) < store.effectiveRating($1) }) { t in
                Button { store.addToBucket([t.id]) } label: { PhoneTrailRow(trail: t) }.tint(.primary)
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Add to Bucket List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
