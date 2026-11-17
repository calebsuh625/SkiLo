import Testing
import Foundation
@testable import SkiLo

@Suite("Style")
struct StyleTests {
    @Test func rampStopsAreExact() {
        for (rating, color) in Ramp.stops { #expect(Ramp.color(for: rating) == color) }
        #expect(Ramp.color(for: 1) == RGBA(hex: "#3BD07C"))
        #expect(Ramp.color(for: 100) == RGBA(hex: "#4A0010"))
    }
    @Test func rampClamps() {
        #expect(Ramp.color(for: -5) == Ramp.color(for: 1))
        #expect(Ramp.color(for: 0) == Ramp.color(for: 1))
        #expect(Ramp.color(for: 250) == Ramp.color(for: 100))
    }
    @Test func rampInterpolatesLinearly() {
        let a = RGBA(hex: "#2EC4A0"), b = RGBA(hex: "#2E9BF0")
        let mid = Ramp.color(for: 20)            // halfway between 15 and 25
        #expect(abs(mid.r - (a.r + b.r) / 2) < 1e-9)
        #expect(abs(mid.g - (a.g + b.g) / 2) < 1e-9)
        #expect(abs(mid.b - (a.b + b.b) / 2) < 1e-9)
        let q = Ramp.color(for: 17)              // 0.2 of the way
        #expect(abs(q.g - (a.g + (b.g - a.g) * 0.2)) < 1e-9)
    }
    @Test func doneColorIsDesaturatedAndLighter() {
        for r in [1, 30, 55, 80, 100] {
            let c = Ramp.color(for: r), d = Ramp.doneColor(for: r)
            let (_, sc, bc) = hsb(c), (_, sd, bd) = hsb(d)
            #expect(abs(sd - sc * 0.3) < 0.01)
            #expect(abs(bd - min(1, bc + 0.15)) < 0.01)
        }
    }
    @Test func textColorPicksContrast() {
        #expect(Ramp.textColor(on: RGBA(hex: "#FFFFFF")) == RGBA(hex: "#0B2E1A"))
        #expect(Ramp.textColor(on: Ramp.color(for: 1)) == RGBA(hex: "#0B2E1A"))      // light spring green
        #expect(Ramp.textColor(on: Ramp.color(for: 100)) == .white)
        #expect(Ramp.textColor(on: .black) == .white)
    }

    private func ctx(visible: Bool = true, selected: Bool = false, hovered: Bool = false, base: MapBaseStyle = .satellite) -> StyleContext {
        StyleContext(isVisible: visible, isSelected: selected, isHovered: hovered, base: base)
    }
    @Test func notVisibleIsDimmed() {
        let s = TrailStyleBuilder.style(rating: 60, status: .bucket, name: "X", context: ctx(visible: false))
        #expect(s.color == RGBA(hex: "#8E8E93")); #expect(s.casing == .clear); #expect(s.opacity == 0.15)
        #expect(s.baseWidth == 1.5); #expect(s.dash == nil); #expect(s.badge == .none); #expect(s.emphasis == .dimmed); #expect(s.label == nil)
    }
    @Test func notDoneRow() {
        let s = TrailStyleBuilder.style(rating: 60, status: .notDone, name: "X", context: ctx())
        #expect(s.color == Ramp.color(for: 60)); #expect(s.casing == .white); #expect(s.opacity == 1)
        #expect(s.baseWidth == 2.5); #expect(s.badge == .none); #expect(s.emphasis == .normal); #expect(s.label == nil)
        #expect(TrailStyleBuilder.style(rating: 60, status: .notDone, name: "X", context: ctx(base: .outline)).casing == RGBA(hex: "#1C1C1E"))
    }
    @Test func bucketRow() {
        let s = TrailStyleBuilder.style(rating: 33, status: .bucket, name: "X", context: ctx())
        #expect(s.color == Ramp.color(for: 33)); #expect(s.casing == RGBA(hex: "#FFD60A")); #expect(s.opacity == 1)
        #expect(s.baseWidth == 3.0); #expect(s.badge == .bucket); #expect(s.emphasis == .normal)
    }
    @Test func doneRow() {
        let s = TrailStyleBuilder.style(rating: 33, status: .done, name: "X", context: ctx())
        #expect(s.color == Ramp.doneColor(for: 33)); #expect(s.casing == .white); #expect(s.opacity == 0.55)
        #expect(s.baseWidth == 2.0); #expect(s.badge == .done); #expect(s.emphasis == .normal)
        #expect(TrailStyleBuilder.style(rating: 33, status: .done, name: "X", context: ctx(base: .outline)).casing == RGBA(hex: "#1C1C1E"))
    }
    @Test func hoveredScalesWidthOnly() {
        for (st, w) in [(TrailStatus.notDone, 2.5), (.bucket, 3.0), (.done, 2.0)] {
            let base = TrailStyleBuilder.style(rating: 50, status: st, name: "X", context: ctx())
            let h = TrailStyleBuilder.style(rating: 50, status: st, name: "X", context: ctx(hovered: true))
            #expect(abs(h.baseWidth - w * 1.3) < 1e-9); #expect(h.opacity == base.opacity); #expect(h.color == base.color)
            #expect(h.casing == base.casing); #expect(h.badge == base.badge); #expect(h.emphasis == .hovered); #expect(h.label == nil)
        }
    }
    @Test func selectedWinsAndShowsLabel() {
        for (st, w) in [(TrailStatus.notDone, 2.5), (.bucket, 3.0), (.done, 2.0)] {
            let s = TrailStyleBuilder.style(rating: 50, status: st, name: "Gunbarrel", context: ctx(selected: true, hovered: true))
            #expect(abs(s.baseWidth - w * 1.8) < 1e-9); #expect(s.opacity == 1); #expect(s.emphasis == .selected); #expect(s.label == "Gunbarrel")
        }
    }
    @Test func filteredOutButSelectedRendersSelected() {
        let s = TrailStyleBuilder.style(rating: 50, status: .notDone, name: "Y", context: ctx(visible: false, selected: true))
        #expect(s.emphasis == .selected); #expect(s.color == Ramp.color(for: 50)); #expect(s.label == "Y")
        let h = TrailStyleBuilder.style(rating: 50, status: .notDone, name: "Y", context: ctx(visible: false, hovered: true))
        #expect(h.emphasis == .dimmed)
    }
    @MainActor @Test func stylesForStoreCoversCatalog() throws {
        let store = try Fixtures.makeStore()
        let styles = TrailStyleBuilder.styles(for: store)
        #expect(styles.count == store.catalog.trails.count)
    }

    private func hsb(_ c: RGBA) -> (Double, Double, Double) {
        let ns = c.nsColor.usingColorSpace(.sRGB)!
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }
}
