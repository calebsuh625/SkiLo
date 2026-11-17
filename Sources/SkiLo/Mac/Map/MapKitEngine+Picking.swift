import AppKit
import MapKit
import QuartzCore

/// Projected trail vertices for one camera (DESIGN §8.3). ≈6.6 k points, ~1 ms to rebuild.
struct ProjectionCache {
    struct Key: Equatable {
        var lat: Double, lon: Double, altitude: Double, pitch: Double, heading: Double
        var width: Double, height: Double
    }
    let key: Key
    let polylines: [ProjectedPolyline]
    let context: MapKitEngine.TerrainContext
}

extension MapKitEngine {
    /// View coordinates (top-left origin) of a ground-plane coordinate; nil when MapKit cannot
    /// project it. `convert(_:toPointTo:)` ignores the realistic terrain.
    func projectRaw(_ c: CLLocationCoordinate2D) -> CGPoint? {
        let m = mapView
        let p = m.convert(c, toPointTo: m)
        guard p.x.isFinite, p.y.isFinite else { return nil }
        return m.isFlipped ? p : CGPoint(x: p.x, y: m.bounds.height - p.y)
    }

    /// Terrain-aware projection. Measured on 2026-11-02 (HT_PROJ_DEBUG screenshot, California
    /// preset 2.5 km / 60°): plain `convert()` put Gunbarrel's vertices ~65 pt away from the drawn,
    /// terrain-draped line, because MapKit's conversion uses a flat plane through the camera's
    /// centre while overlays are draped on the 3D terrain. Fix: treat the vertex as raised by
    /// Δh = ele − ele(centre) above that plane, intersect the eye→vertex ray with the plane, and
    /// convert that plane point (same ray ⇒ same screen point).
    func projectTerrain(_ g: GeoCoordinate, context k: TerrainContext) -> CGPoint? {
        guard let ele = g.ele, let ce = k.centerEle, k.eyeHeight > 1 else { return projectRaw(g.clCoordinate) }
        let dh = ele - ce
        guard k.eyeHeight - dh > 1 else { return nil }      // vertex above the eye: behind the camera plane
        let px = (g.lon - k.center.lon) * k.mPerLon, py = (g.lat - k.center.lat) * k.mPerLat
        let t = k.eyeHeight / (k.eyeHeight - dh)
        let qx = k.eyeX + (px - k.eyeX) * t, qy = k.eyeY + (py - k.eyeY) * t
        return projectRaw(CLLocationCoordinate2D(latitude: k.center.lat + qy / k.mPerLat, longitude: k.center.lon + qx / k.mPerLon))
    }

    struct TerrainContext {
        var center: GeoCoordinate
        var centerEle: Double?
        var eyeX: Double, eyeY: Double, eyeHeight: Double      // metres, local ENU around `center`
        var mPerLat: Double, mPerLon: Double
    }

    func terrainContext() -> TerrainContext {
        let cam = mapView.camera
        let center = GeoCoordinate(lat: cam.centerCoordinate.latitude, lon: cam.centerCoordinate.longitude)
        let pitch = Double(cam.pitch) * .pi / 180, heading = cam.heading * .pi / 180
        let d = cam.centerCoordinateDistance
        let back = d * sin(pitch)                                  // eye sits behind the centre, opposite the heading
        let mPerLat = 110_574.0, mPerLon = 111_320.0 * cos(center.lat * .pi / 180)
        return TerrainContext(center: center, centerEle: groundElevation(near: center),
                              eyeX: -back * sin(heading), eyeY: -back * cos(heading), eyeHeight: d * cos(pitch),
                              mPerLat: mPerLat, mPerLon: mPerLon)
    }

    /// Terrain elevation under `c`, inverse-distance weighted from the 6 nearest catalog vertices
    /// (trail vertices carry DEM elevations); nil when nothing is within 3 km.
    func groundElevation(near c: GeoCoordinate) -> Double? {
        var best: [(d: Double, e: Double)] = []
        let mPerLon = 111_320.0 * cos(c.lat * .pi / 180)
        for t in scene?.trails ?? [] {
            for pl in t.polylines {
                for v in pl {
                    guard let e = v.ele else { continue }
                    let dx = (v.lon - c.lon) * mPerLon, dy = (v.lat - c.lat) * 110_574
                    let d = (dx * dx + dy * dy).squareRoot()
                    if best.count < 6 { best.append((d, e)); best.sort { $0.d < $1.d } }
                    else if d < best[5].d { best[5] = (d, e); best.sort { $0.d < $1.d } }
                }
            }
        }
        guard let first = best.first, first.d < 3_000 else { return nil }
        var w = 0.0, s = 0.0
        for b in best { let wi = 1 / max(b.d, 1); w += wi; s += wi * b.e }
        return s / w
    }

    var cameraKey: ProjectionCache.Key {
        let m = mapView, c = m.camera
        return .init(lat: c.centerCoordinate.latitude, lon: c.centerCoordinate.longitude, altitude: c.altitude,
                     pitch: c.pitch, heading: c.heading, width: m.bounds.width, height: m.bounds.height)
    }

    func projected() -> [ProjectedPolyline] {
        let key = cameraKey
        if let pc = projectionCache, pc.key == key { return pc.polylines }
        var k = terrainContext()
        let dem = k.centerEle
        if let fit = calibratedCenterElevation(base: k) {
            k.centerEle = fit.ele
            if verboseTiming { NSLog("MapKitEngine terrain calibration: plane %.0f m (DEM estimate %.0f m), rms %.1f pt over %d probes", fit.ele, dem ?? -1, fit.rmsPt, fit.n) }
        }
        var out: [ProjectedPolyline] = []
        for t in scene?.trails ?? [] {
            for pl in t.polylines { out.append(ProjectedPolyline(trailID: t.id, points: pl.map { projectTerrain($0, context: k) })) }
        }
        projectionCache = ProjectionCache(key: key, polylines: out, context: k)
        return out
    }

    /// The point a click/hover event refers to, in the map view's top-left-origin coordinates.
    func viewPoint(fromWindow p: NSPoint) -> CGPoint {
        let m = mapView
        var v = m.convert(p, from: nil)
        if !m.isFlipped { v.y = m.bounds.height - v.y }
        return v
    }

    @objc func handleClick(_ gr: NSClickGestureRecognizer) {
        guard gr.state == .ended else { return }
        let m = mapView
        var p = gr.location(in: m)
        if !m.isFlipped { p.y = m.bounds.height - p.y }
        let id = hitTest(p)
        if verboseTiming {
            NSLog("MapKitEngine click at (%.0f, %.0f) → %@ (pick %.0f µs)", p.x, p.y, id ?? "nil", lastPickUs)
        }
        if fly != nil { return }
        if delegate?.mapEngine(self, didClickAt: coordinate(at: p, trailID: id), trailID: id) == true { return }
        delegate?.mapEngine(self, didSelect: id)
    }

    func handleMouseMoved(_ e: NSEvent) {
        let p = viewPoint(fromWindow: e.locationInWindow)
        let now = CACurrentMediaTime()
        let interval = 1.0 / 30
        pendingHover?.cancel()
        if now - lastHoverTime >= interval {
            processHover(at: p, time: now)
        } else {
            let w = DispatchWorkItem { [weak self] in self?.processHover(at: p, time: CACurrentMediaTime()) }
            pendingHover = w
            DispatchQueue.main.asyncAfter(deadline: .now() + (interval - (now - lastHoverTime)), execute: w)
        }
    }

    func processHover(at p: CGPoint, time: TimeInterval) {
        lastHoverTime = time
        let id = hitTest(p)
        guard id != lastHoverID else { return }
        lastHoverID = id
        delegate?.mapEngine(self, didHover: id, at: id == nil ? nil : p)
    }

    func handleMouseExited() {
        pendingHover?.cancel()
        guard lastHoverID != nil else { return }
        lastHoverID = nil
        delegate?.mapEngine(self, didHover: nil, at: nil)
    }
}
