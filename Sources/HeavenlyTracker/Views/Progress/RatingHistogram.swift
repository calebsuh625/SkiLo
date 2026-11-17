import SwiftUI
import Charts

/// Completed trails by rating decile. Click a bar to filter Trails to that range.
struct RatingHistogram: View {
    @Environment(AppStore.self) private var store
    let bins: [ProgressStats.Bin]
    @State private var hovered: String?

    var body: some View {
        Chart {
            ForEach(bins) { b in
                BarMark(x: .value("Rating", b.label), yStart: .value("Start", 0), yEnd: .value("Total", b.total))
                    .foregroundStyle(Ramp.swiftUIColor(for: b.lo + 5).opacity(0.18))
                BarMark(x: .value("Rating", b.label), yStart: .value("Start", 0), yEnd: .value("Done", b.done))
                    .foregroundStyle(Ramp.swiftUIColor(for: b.lo + 5))
            }
            if let h = hovered, let b = bins.first(where: { $0.label == h }) {
                RuleMark(x: .value("Rating", h)).foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text("\(b.label): \(b.done) of \(b.total) done").font(.caption).padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
            }
        }
        .chartXSelection(value: $hovered)
        .chartXAxis { AxisMarks { v in AxisValueLabel().font(.system(size: 9)) } }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { loc in
                    let x = loc.x - geo[proxy.plotFrame!].origin.x
                    if let label = proxy.value(atX: x, as: String.self), let b = bins.first(where: { $0.label == label }) {
                        store.filter.ratingRange = b.lo...b.hi
                        store.section = .trails
                    }
                }
            }
        }
        .accessibilityLabel("Completed trails by rating")
    }
}
