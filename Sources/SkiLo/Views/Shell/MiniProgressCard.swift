import SwiftUI

/// Sidebar footer: skill estimate, done/total bar. Click navigates to Progress.
struct MiniProgressCard: View {
    @Environment(AppStore.self) private var store
    init() {}
    var body: some View {
        let total = max(store.catalog.trails.count, 1)
        let done = store.doneCount
        let skill = store.skill
        Button { store.section = .progress } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Skill").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(skill.rounded)").font(.title3.weight(.bold)).monospacedDigit()
                    if skill.isProvisional { Text("est.").font(.caption2).foregroundStyle(.secondary) }
                }
                ProgressView(value: Double(done), total: Double(total)).tint(Ramp.doneGreen.color)
                Text("\(done)/\(total) done").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Open Progress")
        .accessibilityLabel("Skill \(skill.rounded), \(done) of \(total) trails done")
    }
}
