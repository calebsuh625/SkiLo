import SwiftUI

struct OnboardingSheet: View {
    @Environment(AppStore.self) private var store
    @State private var level: Double = 30
    @State private var backfillGreens = false
    @State private var backfillBlues = false
    init() {}

    private static let anchorIDs = ["t-maggie-s", "t-olympic-downhill", "t-ellie-s", "t-gunbarrel", "t-snake-eyes"]
    private var anchors: [(name: String, rating: Int)] {
        Self.anchorIDs.compactMap { id in store.trail(id).map { ($0.name, $0.rating.total) } }
    }
    private var rating: Int { Int(level.rounded()) }
    private func count(_ band: Band) -> Int { store.catalog.trails.filter { Band.of($0.rating.total) == band }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to SkiLo").font(.title2.weight(.bold))
                Text("How would you rate yourself today?").font(.title3).foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    RatingPill(rating: rating, size: .largeTitle)
                    BandSymbol(band: Band.of(rating)).font(.title2)
                    Text(Band.of(rating).title).font(.title3).foregroundStyle(.secondary)
                    Spacer()
                }
                ZStack {
                    RampTrack().frame(height: 10).clipShape(Capsule()).padding(.horizontal, 2)
                    Slider(value: $level, in: 1...100, step: 1)
                }
                GeometryReader { geo in
                    ForEach(Array(anchors.enumerated()), id: \.offset) { i, a in
                        VStack(spacing: 1) {
                            Image(systemName: "arrowtriangle.up.fill").font(.system(size: 7)).foregroundStyle(.secondary)
                            Text("\(a.rating)").font(.caption.weight(.semibold).monospacedDigit())
                            Text(a.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        }
                        .position(x: 8 + (geo.size.width - 16) * CGFloat(a.rating - 1) / 99, y: i % 2 == 0 ? 20 : 44)
                    }
                }
                .frame(height: 66)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Backfill: I’ve already skied…").font(.headline)
                Toggle("All greens (\(count(.green)) trails)", isOn: $backfillGreens)
                Toggle("All blues (\(count(.blue)) trails)", isOn: $backfillBlues)
                Text("Backfilled trails are marked done but do not count toward streaks. Optional.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Skip") { store.completeOnboarding(selfAssessed: 30, backfill: []) }
                Button("Start") {
                    var b = Set<Band>()
                    if backfillGreens { b.insert(.green) }
                    if backfillBlues { b.insert(.blue) }
                    store.completeOnboarding(selfAssessed: rating, backfill: b)
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 560)
        #else
        .frame(maxWidth: .infinity)
        #endif
        .interactiveDismissDisabled()
    }
}
