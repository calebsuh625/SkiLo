import SwiftUI
import Charts

struct ElevationProfileChart: View {
    let trail: Trail; let units: Units
    @State private var hoverX: Double?
    init(trail: Trail, units: Units) { self.trail = trail; self.units = units }

    private struct Point: Identifiable { let id: Int; let x: Double; let y: Double; let grade: Double }

    private var points: [Point] {
        trail.profile.enumerated().map { i, s in
            Point(id: i, x: units == .imperial ? s.distanceM / 1609.344 : s.distanceM / 1000,
                  y: units == .imperial ? s.elevationM * 3.28084 : s.elevationM, grade: s.gradePct)
        }
    }
    private var xUnit: String { units == .imperial ? "mi" : "km" }
    private var yUnit: String { units == .imperial ? "ft" : "m" }

    /// Grade → colour through the rating ramp (0 % ≈ 1, 67 % and steeper ≈ 100).
    static func gradeColor(_ gradePct: Double) -> Color {
        Ramp.color(for: min(100, max(1, Int((abs(gradePct) * 1.5).rounded())))).color
    }

    private func gradient(_ pts: [Point]) -> LinearGradient {
        guard let maxX = pts.last?.x, maxX > 0 else { return LinearGradient(colors: [.accentColor], startPoint: .leading, endPoint: .trailing) }
        let stops = pts.map { Gradient.Stop(color: Self.gradeColor($0.grade), location: min(1, max(0, $0.x / maxX))) }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        let pts = points
        if pts.count < 2 {
            Text("No elevation profile").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
        } else {
            let lo = pts.map(\.y).min()!, hi = pts.map(\.y).max()!
            let pad = max((hi - lo) * 0.05, 1)
            let g = gradient(pts)
            let hovered = hoverX.flatMap { hx in pts.min { abs($0.x - hx) < abs($1.x - hx) } }
            Chart {
                ForEach(pts) { p in
                    AreaMark(x: .value("Distance", p.x), yStart: .value("Base", lo - pad), yEnd: .value("Elevation", p.y))
                        .interpolationMethod(.catmullRom).foregroundStyle(g.opacity(0.35))
                }
                ForEach(pts) { p in
                    LineMark(x: .value("Distance", p.x), y: .value("Elevation", p.y))
                        .interpolationMethod(.catmullRom).foregroundStyle(g).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                if let h = hovered {
                    RuleMark(x: .value("Distance", h.x))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Text(String(format: "%.2f %@ · %@ %@ · %.0f%%", h.x, xUnit, Self.num(h.y), yUnit, h.grade))
                                .font(.caption2.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        }
                    PointMark(x: .value("Distance", h.x), y: .value("Elevation", h.y)).foregroundStyle(Self.gradeColor(h.grade)).symbolSize(40)
                }
            }
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .chartXAxis { AxisMarks { v in AxisGridLine(); AxisTick(); AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.1f", d)) } } } }
            .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(Self.num(d)) } } } }
            .chartXAxisLabel(xUnit, alignment: .trailing).chartYAxisLabel(yUnit, position: .leading)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                if let frame = proxy.plotFrame { hoverX = proxy.value(atX: loc.x - geo[frame].origin.x, as: Double.self) }
                            case .ended: hoverX = nil
                            }
                        }
                }
            }
            .frame(height: 150)
            .accessibilityLabel("Elevation profile, \(Self.num(hi)) \(yUnit) at top to \(Self.num(lo)) \(yUnit) at bottom")
        }
    }

    private static let numFmt: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f }()
    static func num(_ v: Double) -> String { numFmt.string(from: NSNumber(value: v)) ?? "\(Int(v))" }
}
