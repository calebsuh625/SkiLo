import SwiftUI
import Charts

/// Skill over time: LineMark + AreaMark(low…high) + RuleMarks at 25/50/75 + a PointMark per ski day.
struct SkillChart: View {
    @Environment(AppStore.self) private var store
    let points: [SkillPoint]
    let log: [RunLogEntry]
    @State private var hovered: Date?

    private var nearest: SkillPoint? {
        guard let h = hovered else { return nil }
        return points.min { abs($0.date.timeIntervalSince(h)) < abs($1.date.timeIntervalSince(h)) }
    }

    var body: some View {
        Chart {
            ForEach([25, 50, 75], id: \.self) { y in
                RuleMark(y: .value("Band", y)).foregroundStyle(.secondary.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))

            }
            ForEach(points, id: \.date) { p in
                AreaMark(x: .value("Date", p.date), yStart: .value("Low", p.low), yEnd: .value("High", p.high))
                    .foregroundStyle(Color.accentColor.opacity(0.18))
                LineMark(x: .value("Date", p.date), y: .value("Elo", p.value)).foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Date", p.date), y: .value("Elo", p.value)).foregroundStyle(Color.accentColor).symbolSize(p.runCount == 0 ? 30 : 50)
            }
            if let n = nearest {
                RuleMark(x: .value("Date", n.date)).foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, alignment: .center, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { callout(n) }
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) }
        .chartXSelection(value: $hovered)
        .accessibilityLabel("Elo over time")
    }

    private func callout(_ p: SkillPoint) -> some View {
        let cal = Calendar.current
        let dayRuns = log.filter { cal.isDate($0.date, inSameDayAs: p.date) }
        let best = dayRuns.max { store.effectiveRating($0.trailID) < store.effectiveRating($1.trailID) }
        var s = "\(p.date.formatted(.dateTime.month(.abbreviated).day())) · \(Int(p.value.rounded())) (±\(Int(((p.high - p.low) / 2).rounded())))"
        if p.runCount == 0 { s += " · starting estimate" }
        else {
            s += " · \(dayRuns.count) run\(dayRuns.count == 1 ? "" : "s")"
            if let b = best, let t = store.trail(b.trailID) { s += ", best \(t.name) \(store.effectiveRating(t))" }
        }
        return Text(s).font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
