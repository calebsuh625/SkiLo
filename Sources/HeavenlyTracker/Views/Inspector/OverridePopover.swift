import SwiftUI

extension Notification.Name {
    /// Posted by Trail > Override Rating… (Cmd+Shift+R) and the Trails context menu; observed by TrailInspector.
    static let htOverrideRating = Notification.Name("HeavenlyTracker.overrideRating")
}

/// Bridges "open the override popover" requests to an inspector that may not exist yet
/// (it is created when the inspector is shown), so a request is also remembered until consumed.
@MainActor
enum OverrideCoordinator {
    static var pendingTrail: Trail.ID?
    static func request(for id: Trail.ID, store: AppStore) {
        store.select(id, showInspector: true)
        pendingTrail = id
        DispatchQueue.main.async { NotificationCenter.default.post(name: .htOverrideRating, object: id) }
    }
}

struct OverridePopover: View {
    @Environment(AppStore.self) private var store
    let trailID: Trail.ID; @Binding var isPresented: Bool
    @State private var value: Double = 50
    @State private var note: String = ""
    @State private var loaded = false
    init(trailID: Trail.ID, isPresented: Binding<Bool>) { self.trailID = trailID; self._isPresented = isPresented }

    private var rating: Int { Int(value.rounded()) }
    private var computed: Int { store.trail(trailID)?.rating.total ?? 0 }
    private var hasOverride: Bool { store.state(for: trailID).ratingOverride != nil }
    private var canSave: Bool { !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Override rating").font(.headline)
            HStack(spacing: 10) {
                RatingPill(rating: rating, isOverride: true, size: .title3)
                BandSymbol(band: Band.of(rating))
                Text(Band.of(rating).title).foregroundStyle(.secondary)
                Spacer()
                Text("computed \(computed)").font(.caption).foregroundStyle(.secondary)
            }
            ZStack {
                RampTrack().frame(height: 8).clipShape(Capsule()).padding(.horizontal, 2)
                Slider(value: $value, in: 1...100, step: 1)
            }
            TextField("Why? (required)", text: $note, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder)
            HStack {
                if hasOverride {
                    Button("Reset") { store.setOverride(trailID, rating: nil, note: nil); isPresented = false }
                }
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.setOverride(trailID, rating: rating, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(16).frame(width: 320)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let s = store.state(for: trailID)
            value = Double(s.ratingOverride ?? computed)
            note = s.ratingOverrideNote ?? ""
        }
    }
}

/// The 1–100 colour ramp as a horizontal gradient.
struct RampTrack: View {
    var body: some View {
        LinearGradient(stops: Ramp.stops.map { .init(color: $0.color.color, location: Double($0.rating - 1) / 99) },
                       startPoint: .leading, endPoint: .trailing)
    }
}
