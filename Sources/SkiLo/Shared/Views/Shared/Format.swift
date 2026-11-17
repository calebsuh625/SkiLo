import Foundation
enum Format {
    private static let num: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f }()
    static func length(_ m: Double, _ u: Units) -> String {
        switch u { case .imperial: String(format: "%.1f mi", m / 1609.344); case .metric: String(format: "%.1f km", m / 1000) }
    }
    /// Like `length`, but short distances in feet / metres ("350 ft", "0.4 mi").
    static func distance(_ m: Double, _ u: Units) -> String {
        switch u {
        case .imperial: m < 160 ? String(format: "%.0f ft", (m * 3.28084 / 10).rounded() * 10) : String(format: "%.1f mi", m / 1609.344)
        case .metric: m < 1000 ? String(format: "%.0f m", (m / 10).rounded() * 10) : String(format: "%.1f km", m / 1000)
        }
    }
    static func elevation(_ m: Double, _ u: Units) -> String {
        switch u { case .imperial: (num.string(from: NSNumber(value: m * 3.28084)) ?? "") + " ft"; case .metric: (num.string(from: NSNumber(value: m)) ?? "") + " m" }
    }
    static func vert(_ m: Double, _ u: Units) -> String { elevation(m, u) }
    static func grade(_ pct: Double) -> String { String(format: "%.0f%%", pct) }
    static func date(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .omitted) }
    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
}

import SwiftUI

extension View {
    /// A text-link button: `.link` on the Mac, borderless (tinted text) on iPhone.
    @ViewBuilder func linkButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }
}
