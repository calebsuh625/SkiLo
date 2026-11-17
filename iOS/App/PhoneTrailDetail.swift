import SwiftUI

/// One trail: rating, readiness, Elo worth, the main actions, stats, profile and "why".
struct PhoneTrailDetail: View {
    @Environment(AppStore.self) private var store
    let trailID: Trail.ID

    var body: some View {
        if let t = store.trail(trailID) {
            content(t)
        } else {
            ContentUnavailableView("Trail not found", systemImage: "questionmark.circle")
        }
    }

    private func content(_ t: Trail) -> some View {
        let s = store.state(for: t.id)
        let rating = store.effectiveRating(t)
        let units = store.userData.profile.units
        return List {
            Section {
                HStack(spacing: 14) {
                    RatingPill(rating: rating, isOverride: s.ratingOverride != nil, size: .largeTitle)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) { BandSymbol(band: Band.of(rating)); Text(Band.of(rating).title) }.font(.headline)
                        Text("\(t.area.title) · \(t.subArea.title)").font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ReadinessChip(readiness: store.readiness(for: t.id))
                            Label("\(Elo.formatDelta(store.eloPreview(for: t.id)) ?? "+0.0") Elo", systemImage: "trophy.fill")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                if s.isDone {
                    Button { store.recordAnotherRun(t.id) } label: { Label("Ran It Again", systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { store.markNotDone(t.id) } label: { Label("Mark Not Done", systemImage: "arrow.uturn.backward") }
                } else {
                    Button { store.markDone(t.id) } label: { Label("Mark Done", systemImage: "checkmark.circle.fill") }
                }
                Button { store.requestLogRun(trailID: t.id) } label: { Label("Log Run…", systemImage: "plus.circle") }
                Button { store.toggleBucket(t.id) } label: {
                    s.bucketedAt == nil ? Label("Add to Bucket List", systemImage: "star") : Label("Remove from Bucket List", systemImage: "star.slash")
                }
                Button { store.showOnMap(t.id) } label: { Label("Show on Map", systemImage: "map") }
            } footer: {
                if s.timesSkied > 0, let first = s.firstDoneDate {
                    Text("Skied \(s.timesSkied)× · first \(Format.date(first))")
                }
            }

            Section("Stats") {
                stat("Length", Format.length(t.stats.lengthM, units))
                stat("Vertical", Format.vert(t.stats.verticalDropM, units))
                stat("Average grade", Format.grade(t.stats.avgGradePct))
                stat("Steepest pitch", Format.grade(t.stats.maxGradePct))
                stat("Top / bottom", "\(Format.elevation(t.stats.topElevM, units)) / \(Format.elevation(t.stats.bottomElevM, units))")
            }
            Section("Elevation profile") {
                ElevationProfileChart(trail: t, units: units).frame(height: 160)
            }
            Section("Why \(rating)?") {
                RatingBreakdownView(breakdown: t.rating, override: s.ratingOverride, note: s.ratingOverrideNote)
            }
        }
        .navigationTitle(t.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).monospacedDigit() }
    }
}
