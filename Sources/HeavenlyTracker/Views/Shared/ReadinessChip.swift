import SwiftUI
struct ReadinessChip: View {
    let readiness: Readiness
    init(readiness: Readiness) { self.readiness = readiness }
    var body: some View {
        Text(label).font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
    }
    private var label: String {
        switch readiness.kind {
        case .ready: "ready"
        case .stretch: "stretch +\(readiness.delta)"
        case .bigStretch: "big stretch +\(readiness.delta)"
        case .belowYou: "below you"
        }
    }
    private var color: Color {
        switch readiness.kind {
        case .ready: RGBA(hex: "#34C759").color
        case .stretch: RGBA(hex: "#FF9F0A").color
        case .bigStretch: RGBA(hex: "#FF453A").color
        case .belowYou: RGBA(hex: "#8E8E93").color
        }
    }
}
