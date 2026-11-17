import SwiftUI
import AppKit

/// UX_SPEC §8.1 continuous 1–100 ramp.
enum Ramp {
    static let stops: [(rating: Int, color: RGBA)] = [
        (1, RGBA(hex: "#3BD07C")), (15, RGBA(hex: "#2EC4A0")), (25, RGBA(hex: "#2E9BF0")), (40, RGBA(hex: "#2F6BE6")),
        (50, RGBA(hex: "#5A4FD8")), (62, RGBA(hex: "#7E3FC9")), (75, RGBA(hex: "#B8336A")), (88, RGBA(hex: "#C8102E")),
        (100, RGBA(hex: "#4A0010")),
    ]
    /// Piecewise-linear sRGB between the stops; rating clamped to 1…100.
    static func color(for rating: Int) -> RGBA {
        let r = min(max(rating, 1), 100)
        for i in 1..<stops.count where r <= stops[i].rating {
            let a = stops[i - 1], b = stops[i]
            return RGBA.lerp(a.color, b.color, Double(r - a.rating) / Double(b.rating - a.rating))
        }
        return stops[stops.count - 1].color
    }
    /// Desaturate 70 % (saturation × 0.3) and lighten (brightness + 0.15, capped at 1) in HSB.
    static func doneColor(for rating: Int) -> RGBA {
        let c = color(for: rating)
        guard let ns = c.nsColor.usingColorSpace(.sRGB) else { return c }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let out = NSColor(hue: h, saturation: s * 0.3, brightness: min(1, b + 0.15), alpha: a)
        guard let rgb = out.usingColorSpace(.sRGB) else { return c }
        return RGBA(r: Double(rgb.redComponent), g: Double(rgb.greenComponent), b: Double(rgb.blueComponent), a: Double(rgb.alphaComponent))
    }
    /// Legible text on a ramp fill: luminance > 0.5 → dark green-black, else white.
    static func textColor(on background: RGBA) -> RGBA { background.luminance > 0.5 ? RGBA(hex: "#0B2E1A") : .white }
    static func swiftUIColor(for rating: Int) -> Color { color(for: rating).color }
    static let doneGreen = RGBA(hex: "#34C759")
    static let bucketYellow = RGBA(hex: "#FFD60A")
    static let dimmedGray = RGBA(hex: "#8E8E93")
    static let connectorGray = RGBA(hex: "#C7C7CC")
    static let liftGray = RGBA(hex: "#3A3A3C")
}
