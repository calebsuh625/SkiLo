import SwiftUI

struct MilestoneGrid: View {
    @Environment(AppStore.self) private var store
    @State private var shown: String?

    var body: some View {
        let ctx = MilestoneContext(userData: store.userData, catalog: store.catalog, ratings: store.effectiveRatings)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(MilestoneRegistry.all) { m in
                let ev = MilestoneRegistry.evaluate(m, in: ctx)
                let unlocked = ev == .achieved
                Button { shown = shown == m.id ? nil : m.id } label: {
                    HStack(spacing: 6) {
                        Image(systemName: unlocked ? "rosette" : m.symbol).foregroundStyle(unlocked ? Ramp.bucketYellow.color : .secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(m.title).font(.callout.weight(.medium)).lineLimit(1)
                            Text(sub(m, ev)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(unlocked ? Ramp.doneGreen.color.opacity(0.15) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .opacity(unlocked ? 1 : 0.8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(get: { shown == m.id }, set: { if !$0 && shown == m.id { shown = nil } })) {
                    Text(m.detail).padding(10)
                }
            }
        }
    }

    private func sub(_ m: Milestone, _ ev: MilestoneEvaluation) -> String {
        switch ev {
        case .achieved:
            if let d = store.userData.profile.unlockedMilestones[m.id] { return "Unlocked " + Format.date(d) }
            return "Achieved"
        case .locked(let f): return f.map { "\(Int(($0 * 100).rounded()))%" } ?? "Locked"
        }
    }
}
