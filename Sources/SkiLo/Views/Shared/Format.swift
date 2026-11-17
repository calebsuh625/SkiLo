import Foundation
enum Format {
    private static let num: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f }()
    static func length(_ m: Double, _ u: Units) -> String {
        switch u { case .imperial: String(format: "%.1f mi", m / 1609.344); case .metric: String(format: "%.1f km", m / 1000) }
    }
    static func elevation(_ m: Double, _ u: Units) -> String {
        switch u { case .imperial: (num.string(from: NSNumber(value: m * 3.28084)) ?? "") + " ft"; case .metric: (num.string(from: NSNumber(value: m)) ?? "") + " m" }
    }
    static func vert(_ m: Double, _ u: Units) -> String { elevation(m, u) }
    static func grade(_ pct: Double) -> String { String(format: "%.0f%%", pct) }
    static func date(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .omitted) }
    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
}
