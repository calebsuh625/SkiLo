import SwiftUI
import AppKit

struct RGBA: Hashable, Codable, Sendable {
    var r: Double, g: Double, b: Double, a: Double
    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    /// "#RRGGBB" or "RRGGBB"
    init(hex: String, alpha: Double = 1) {
        var h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let v = UInt32(h, radix: 16) ?? 0
        self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: alpha)
    }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    func withAlpha(_ alpha: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }
    static func lerp(_ x: RGBA, _ y: RGBA, _ t: Double) -> RGBA {
        let u = min(max(t, 0), 1)
        return RGBA(r: x.r + (y.r - x.r) * u, g: x.g + (y.g - x.g) * u, b: x.b + (y.b - x.b) * u, a: x.a + (y.a - x.a) * u)
    }
    static let white = RGBA(r: 1, g: 1, b: 1)
    static let black = RGBA(r: 0, g: 0, b: 0)
    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
    static let gray  = RGBA(hex: "#8E8E93")
}
