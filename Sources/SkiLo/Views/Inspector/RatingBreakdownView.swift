import SwiftUI

/// Renders whatever components the engine returns, in order, then Total and the override row.
struct RatingBreakdownView: View {
    let breakdown: RatingBreakdown; let override: Int?; let note: String?
    init(breakdown: RatingBreakdown, override: Int?, note: String?) { self.breakdown = breakdown; self.override = override; self.note = note }

    private var maxMagnitude: Double { max(breakdown.components.map { abs($0.points) }.max() ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(breakdown.components.enumerated()), id: \.offset) { _, c in
                HStack(spacing: 8) {
                    Text(c.label).font(.callout).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        .help(c.detail)
                    GeometryReader { geo in
                        let w = geo.size.width * CGFloat(abs(c.points) / maxMagnitude)
                        HStack(spacing: 0) {
                            if c.points < 0 { Spacer(minLength: 0) }
                            RoundedRectangle(cornerRadius: 2).fill(c.points >= 0 ? Color.orange : Color.teal).frame(width: max(w, c.points == 0 ? 0 : 2))
                            if c.points >= 0 { Spacer(minLength: 0) }
                        }
                    }
                    .frame(width: 56, height: 8)
                    Text(Self.signed(c.points)).font(.callout.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
            }
            Divider()
            HStack {
                Text("Computed").font(.callout.weight(.semibold))
                Spacer()
                Text("\(breakdown.total)").font(.callout.weight(.semibold).monospacedDigit())
            }
            if let override {
                HStack(alignment: .firstTextBaseline) {
                    Label("Your override", systemImage: "pencil").font(.callout)
                    Spacer()
                    Text("\(override)").font(.callout.weight(.semibold).monospacedDigit())
                }
                if let note, !note.isEmpty { Text("“\(note)”").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    static func signed(_ p: Double) -> String {
        let r = Int(p.rounded())
        return r > 0 ? "+\(r)" : r < 0 ? "\u{2212}\(abs(r))" : "0"
    }
}
