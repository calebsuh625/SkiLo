import SwiftUI

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
        let (h, s, v) = hsb(c)
        let (r, g, b) = rgb(h: h, s: s * 0.3, v: min(1, v + 0.15))
        return RGBA(r: r, g: g, b: b, a: c.a)
    }
    /// sRGB → hue (0…1), saturation, brightness.
    static func hsb(_ c: RGBA) -> (Double, Double, Double) {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == c.r { h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == c.g { h = (c.b - c.r) / d + 2 }
            else { h = (c.r - c.g) / d + 4 }
            h /= 6; if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }
    static func rgb(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
        let i = Int((h * 6).rounded(.down)) % 6, f = h * 6 - (h * 6).rounded(.down)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
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
