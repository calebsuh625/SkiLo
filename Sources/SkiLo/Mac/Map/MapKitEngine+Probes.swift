import AppKit
import MapKit

/// Invisible terrain probes (one per trail, at a vertex with a known DEM elevation). MapKit places
/// annotation views on the realistic terrain, so a probe view's centre is where MapKit actually
/// drew that vertex. `calibratedCenterElevation` fits the one unknown of the terrain-aware
/// projection (the elevation of MapKit's conversion plane) to the visible probes.
final class ProbeAnnotation: NSObject, MKAnnotation {
    let vertex: GeoCoordinate
    var coordinate: CLLocationCoordinate2D { vertex.clCoordinate }
    init(vertex: GeoCoordinate) { self.vertex = vertex }
}

final class ProbeView: MKAnnotationView {
    static let reuseID = "probe"
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = NSRect(x: 0, y: 0, width: 2, height: 2)
        alphaValue = 0
        displayPriority = .required
        collisionMode = .none
        canShowCallout = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension MapKitEngine {
    func makeProbes(for scene: MapScene) -> [ProbeAnnotation] {
        scene.trails.compactMap { t in
            let all = t.polylines.flatMap { $0 }.filter { $0.ele != nil }
            return all.isEmpty ? nil : ProbeAnnotation(vertex: all[all.count / 2])
        }
    }

    /// Screen positions (top-left origin) of the probes MapKit currently shows inside the view.
    func visibleProbes() -> [(GeoCoordinate, CGPoint)] {
        let m = mapView
        var out: [(GeoCoordinate, CGPoint)] = []
        for a in probes {
            guard let v = m.view(for: a), !v.isHidden else { continue }
            let f = v.frame
            var p = CGPoint(x: f.midX, y: f.midY)
            if !m.isFlipped { p.y = m.bounds.height - p.y }
            if m.bounds.insetBy(dx: 4, dy: 4).contains(p) { out.append((a.vertex, p)) }
        }
        return out
    }

    /// Least-squares fit of the plane elevation (golden-section search, 1,500–3,300 m).
    /// Returns nil when fewer than 3 probes are visible (the caller keeps the DEM estimate).
    func calibratedCenterElevation(base: TerrainContext) -> (ele: Double, rmsPt: Double, n: Int)? {
        let pr = visibleProbes()
        guard pr.count >= 3 else { return nil }
        func cost(_ h: Double) -> Double {
            var k = base; k.centerEle = h
            var s = 0.0
            for (g, p) in pr {
                guard let q = projectTerrain(g, context: k) else { s += 1e6; continue }
                let dx = q.x - p.x, dy = q.y - p.y
                s += Double(dx * dx + dy * dy)
            }
            return s / Double(pr.count)
        }
        var a = 1_500.0, b = 3_300.0
        let r = (5.0.squareRoot() - 1) / 2
        var c = b - r * (b - a), d = a + r * (b - a)
        var fc = cost(c), fd = cost(d)
        for _ in 0..<40 {
            if fc < fd { b = d; d = c; fd = fc; c = b - r * (b - a); fc = cost(c) }
            else { a = c; c = d; fc = fd; d = a + r * (b - a); fd = cost(d) }
        }
        let h = (a + b) / 2
        return (h, cost(h).squareRoot(), pr.count)
    }
}
