import AppKit
import MapKit

/// One OSM way of a named trail (DESIGN §8.2). `isSelectionCopy` marks the hidden glow and the
/// hidden top-layer casing/stroke that become visible only while the trail is selected.
final class TrailOverlay: MKPolyline {
    enum Role { case casing, stroke, glow }
    private(set) var trailID: Trail.ID = ""
    private(set) var wayIndex = 0
    private(set) var role: Role = .stroke
    private(set) var isSelectionCopy = false

    static func make(_ coords: [GeoCoordinate], trailID: Trail.ID, wayIndex: Int, role: Role, isSelectionCopy: Bool = false) -> TrailOverlay {
        let c = coords.map(\.clCoordinate)
        let o = TrailOverlay(coordinates: c, count: c.count)
        o.trailID = trailID; o.wayIndex = wayIndex; o.role = role; o.isSelectionCopy = isSelectionCopy
        return o
    }
}

/// Boundary, connectors and lifts: styled from constants, never selectable.
final class StaticOverlay: MKPolyline {
    enum Role { case boundary, connector, liftCasing, lift }
    private(set) var role: Role = .connector
    private(set) var liftKind: LiftKind?

    static func make(_ coords: [GeoCoordinate], role: Role, liftKind: LiftKind? = nil) -> StaticOverlay {
        let c = coords.map(\.clCoordinate)
        let o = StaticOverlay(coordinates: c, count: c.count)
        o.role = role; o.liftKind = liftKind
        return o
    }
}

extension MapKitEngine {
    static let fallbackStyle = TrailStyle(color: .gray, casing: .white, opacity: 1, baseWidth: 2.5, dash: nil,
                                          badge: .none, emphasis: .normal, label: nil)

    func renderer(for overlay: MKOverlay) -> MKOverlayRenderer {
        if let o = overlay as? TrailOverlay {
            let r = MKPolylineRenderer(polyline: o)
            renderers[ObjectIdentifier(o)] = r
            styleTrailRenderer(r, o)
            return r
        }
        if let o = overlay as? StaticOverlay {
            let r = MKPolylineRenderer(polyline: o)
            renderers[ObjectIdentifier(o)] = r
            styleStaticRenderer(r, o)
            return r
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    /// Mutates the cached renderers of one trail (base and selection copies) — no overlay churn.
    func restyle(_ id: Trail.ID) {
        for o in (trailOverlays[id] ?? []) + selectionOverlays.filter({ $0.trailID == id }) { if let r = renderers[ObjectIdentifier(o)] { styleTrailRenderer(r, o); r.setNeedsDisplay() } }
    }

    func restyleStatic() {
        for case let o as StaticOverlay in staticOverlays {
            if let r = renderers[ObjectIdentifier(o)] { styleStaticRenderer(r, o); r.setNeedsDisplay() }
        }
    }

    func styleTrailRenderer(_ r: MKPolylineRenderer, _ o: TrailOverlay) {
        let style = lastStyles[o.trailID] ?? Self.fallbackStyle
        let flash = flashing.contains(o.trailID)
        let w = max(0.5, style.baseWidth) * widthScale * (flash ? 2.2 : 1)
        r.lineJoin = .round
        r.lineCap = .round
        r.lineDashPattern = nil
        // Selection layers are hidden with a clear stroke colour, not alpha 0: renderers that start
        // at alpha 0 were never drawn again after alpha → 1 (verified by screenshot), while colour
        // mutation redraws reliably. Selected = fully opaque even if done (UX §2.2).
        let hidden = o.isSelectionCopy && o.trailID != selectedID
        r.alpha = o.isSelectionCopy ? 1 : CGFloat(style.opacity)
        switch o.role {
        case .casing:
            r.strokeColor = (flash ? RGBA.white : style.casing).nsColor
            r.lineWidth = w + 2
        case .stroke:
            r.strokeColor = (flash ? RGBA.white : style.color).nsColor
            r.lineWidth = w
            if let d = style.dash, !d.isEmpty {
                r.lineDashPattern = d.map { NSNumber(value: $0) }
                r.lineCap = .butt
            }
        case .glow:
            r.strokeColor = NSColor.white.withAlphaComponent(0.6)
            r.lineWidth = w * 1.8 + 8
        }
        if hidden { r.strokeColor = NSColor.white.withAlphaComponent(0.01) }
    }

    func styleStaticRenderer(_ r: MKPolylineRenderer, _ o: StaticOverlay) {
        let outline = baseStyle == .outline
        let s = widthScale
        r.lineJoin = .round
        r.lineCap = .round
        r.lineDashPattern = nil
        switch o.role {
        case .boundary:
            r.strokeColor = outline ? NSColor(white: 0.25, alpha: 1) : .white
            r.alpha = 0.6
            r.lineWidth = 1
            r.lineDashPattern = [4, 4]
            r.lineCap = .butt
        case .connector:
            r.strokeColor = (outline ? Ramp.dimmedGray : Ramp.connectorGray).nsColor
            r.alpha = 0.5
            r.lineWidth = min(2.5, 1.5 * s)
        case .liftCasing:
            r.strokeColor = .white
            r.alpha = 0.9
            r.lineWidth = min(3, 1.5 * s) + 2
        case .lift:
            r.strokeColor = Ramp.liftGray.nsColor
            r.alpha = 0.9
            r.lineWidth = min(3, 1.5 * s)
            r.lineDashPattern = [6, 4]
            r.lineCap = .butt
        }
    }
}
