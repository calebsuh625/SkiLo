import AppKit
import MapKit
import QuartzCore

/// One leg of a drawn route (directions or a planned day).
final class RouteOverlay: MKPolyline {
    enum Role { case casing, stroke }
    private(set) var role: Role = .stroke
    private(set) var kind: MapRoute.Leg.Kind = .ski
    private(set) var focused = false

    static func make(_ coords: [GeoCoordinate], role: Role, kind: MapRoute.Leg.Kind, focused: Bool) -> RouteOverlay {
        let c = coords.map(\.clCoordinate)
        let o = RouteOverlay(coordinates: c, count: c.count)
        o.role = role; o.kind = kind; o.focused = focused
        return o
    }
}

final class RoutePinAnnotation: NSObject, MKAnnotation {
    enum Kind { case start, end, flyer }
    let kind: Kind
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(kind: Kind, coordinate: CLLocationCoordinate2D) { self.kind = kind; self.coordinate = coordinate }
}

final class RoutePinView: MKAnnotationView {
    static let reuseID = "RoutePin"
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func configure(_ kind: RoutePinAnnotation.Kind) {
        let (symbol, color, d): (String, NSColor, CGFloat) = switch kind {
        case .start: ("figure.skiing.downhill", NSColor(srgbRed: 0.13, green: 0.7, blue: 0.35, alpha: 1), 26)
        case .end: ("flag.checkered", NSColor(srgbRed: 0.9, green: 0.16, blue: 0.25, alpha: 1), 26)
        case .flyer: ("figure.skiing.downhill", MapKitEngine.routeColor, 30)
        }
        image = Self.disc(symbol: symbol, color: color, diameter: d)
        centerOffset = .zero
        zPriority = .max
    }
    static func disc(symbol: String, color: NSColor, diameter d: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: d, height: d), flipped: false) { r in
            let circle = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            color.setFill(); circle.fill()
            NSColor.white.setStroke(); circle.lineWidth = 2; circle.stroke()
            let cfg = NSImage.SymbolConfiguration(pointSize: d * 0.5, weight: .bold).applying(.init(paletteColors: [.white]))
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let s = img.size
                img.draw(in: NSRect(x: (d - s.width) / 2, y: (d - s.height) / 2, width: s.width, height: s.height))
            }
            return true
        }
    }
}

extension MapKitEngine {
    static let routeColor = NSColor(srgbRed: 1.0, green: 0.24, blue: 0.65, alpha: 1)      // hot pink: not on the difficulty ramp
    static let routeFocusColor = NSColor(srgbRed: 1.0, green: 0.85, blue: 0.1, alpha: 1)

    func setRoute(_ route: MapRoute?) {
        guard route != currentRoute else { return }
        currentRoute = route
        let m = mapView
        if !routeOverlays.isEmpty {
            m.removeOverlays(routeOverlays)
            for o in routeOverlays { renderers[ObjectIdentifier(o)] = nil }
            routeOverlays = []
        }
        m.removeAnnotations(routePins)
        routePins = []
        guard let route else { return }
        var casings: [RouteOverlay] = [], strokes: [RouteOverlay] = []
        for leg in route.legs where leg.coords.count >= 2 {
            casings.append(.make(leg.coords, role: .casing, kind: leg.kind, focused: leg.focused))
            strokes.append(.make(leg.coords, role: .stroke, kind: leg.kind, focused: leg.focused))
        }
        // Focused leg last so it draws on top.
        let ordered = casings.filter { !$0.focused } + strokes.filter { !$0.focused } + casings.filter(\.focused) + strokes.filter(\.focused)
        routeOverlays = ordered
        m.addOverlays(ordered, level: .aboveRoads)
        if let s = route.start { routePins.append(RoutePinAnnotation(kind: .start, coordinate: s.clCoordinate)) }
        if let e = route.end { routePins.append(RoutePinAnnotation(kind: .end, coordinate: e.clCoordinate)) }
        m.addAnnotations(routePins)
    }

    func routeRenderer(for o: RouteOverlay) -> MKPolylineRenderer {
        let r = MKPolylineRenderer(polyline: o)
        renderers[ObjectIdentifier(o)] = r
        styleRouteRenderer(r, o)
        return r
    }

    func styleRouteRenderer(_ r: MKPolylineRenderer, _ o: RouteOverlay) {
        let w = (o.focused ? 6.0 : 4.5) * widthScale
        r.lineJoin = .round
        r.lineCap = .round
        r.lineDashPattern = nil
        switch o.role {
        case .casing:
            r.strokeColor = .white
            r.alpha = 0.95
            r.lineWidth = w + 3
        case .stroke:
            r.strokeColor = o.focused ? Self.routeFocusColor : Self.routeColor
            r.alpha = 1
            r.lineWidth = w
            switch o.kind {
            case .lift: r.lineDashPattern = [8, 5]; r.lineCap = .butt
            case .traverse: r.lineDashPattern = [2, 5]
            case .ski: break
            }
        }
    }

    func restyleRoute() {
        for o in routeOverlays { if let r = renderers[ObjectIdentifier(o)] { styleRouteRenderer(r, o); r.setNeedsDisplay() } }
    }

    func routePinView(for a: RoutePinAnnotation) -> MKAnnotationView {
        let v = (mapView.dequeueReusableAnnotationView(withIdentifier: RoutePinView.reuseID) as? RoutePinView)
            ?? RoutePinView(annotation: a, reuseIdentifier: RoutePinView.reuseID)
        v.annotation = a
        v.configure(a.kind)
        return v
    }

    /// Best-effort ground coordinate under a view point: the nearest drawn trail vertex when the
    /// click is on a trail (terrain-exact), else MapKit's flat-plane conversion.
    func coordinate(at p: CGPoint, trailID: Trail.ID?) -> GeoCoordinate {
        if let trailID, let t = trailIndex[trailID], let k = projectionCache?.context {
            var best: (GeoCoordinate, CGFloat)?
            for pl in t.polylines {
                for c in pl {
                    guard let q = projectTerrain(c, context: k) else { continue }
                    let d = hypot(q.x - p.x, q.y - p.y)
                    if best == nil || d < best!.1 { best = (c, d) }
                }
            }
            if let b = best { return b.0 }
        }
        let m = mapView
        let flipped = m.isFlipped ? p : CGPoint(x: p.x, y: m.bounds.height - p.y)
        let c = m.convert(flipped, toCoordinateFrom: m)
        return GeoCoordinate(lat: c.latitude, lon: c.longitude)
    }
}

// MARK: - Fly-through

/// Resampled path with per-sample timing, labels and kinds.
struct FlyPath {
    var points: [GeoCoordinate] = []
    /// Seconds of fly time at which each point is reached.
    var times: [Double] = []
    var labels: [String] = []
    var kinds: [MapRoute.Leg.Kind] = []
    var duration: Double { times.last ?? 0 }

    /// Ski at ~50 m/s of fly time, lifts faster, so a long day still plays in a minute or two.
    init(_ req: FlyRequest, stepM: Double = 8) {
        let total = req.segments.reduce(0.0) { $0 + Self.length($1.coords) }
        // A whole day of skiing still plays in about two and a half minutes at most.
        let speedUp = max(1, total / 50 / 150)
        var t = 0.0
        for seg in req.segments where seg.coords.count >= 2 {
            let speed: Double = switch seg.kind { case .ski: 50; case .lift: 140; case .traverse: 70 }
            let pts = Self.resample(seg.coords, stepM: stepM)
            for (i, p) in pts.enumerated() {
                if let last = points.last, i > 0 || p.distance(to: last) > 0.5 {
                    t += p.distance(to: last) / (speed * speedUp)
                }
                points.append(p); times.append(t); labels.append(seg.label); kinds.append(seg.kind)
            }
        }
    }

    static func length(_ c: [GeoCoordinate]) -> Double { zip(c, c.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) } }

    static func resample(_ c: [GeoCoordinate], stepM: Double) -> [GeoCoordinate] {
        guard c.count >= 2 else { return c }
        var out = [c[0]]
        var carry = 0.0
        for (a, b) in zip(c, c.dropFirst()) {
            let d = a.distance(to: b)
            guard d > 0 else { continue }
            var s = stepM - carry
            while s <= d {
                let f = s / d
                out.append(GeoCoordinate(lat: a.lat + (b.lat - a.lat) * f, lon: a.lon + (b.lon - a.lon) * f,
                                         ele: a.ele.flatMap { ea in b.ele.map { ea + ($0 - ea) * f } }))
                s += stepM
            }
            carry = d - (s - stepM)
        }
        if let last = c.last, out.last.map({ $0.distance(to: last) > 1 }) ?? true { out.append(last) }
        return out
    }

    /// Index of the last point reached at fly time `t`.
    func index(at t: Double) -> Int {
        var lo = 0, hi = times.count - 1
        guard hi > 0 else { return 0 }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    static func bearing(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let φ1 = a.lat * .pi / 180, φ2 = b.lat * .pi / 180, Δλ = (b.lon - a.lon) * .pi / 180
        let y = sin(Δλ) * cos(φ2), x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

final class FlyThroughState {
    var path: FlyPath
    var t = 0.0
    var heading: Double
    var paused = false
    var lastTick = CACurrentMediaTime()
    var lastKeyframe = 0.0
    var timer: Timer?
    var progress: (Double, String) -> Void
    var finished: () -> Void
    init(path: FlyPath, heading: Double, progress: @escaping (Double, String) -> Void, finished: @escaping () -> Void) {
        self.path = path; self.heading = heading; self.progress = progress; self.finished = finished
    }
}

extension MapKitEngine {
    static let flyDistanceM = 1_800.0
    static let flyPitch = 58.0

    func startFlyThrough(_ req: FlyRequest, progress: @escaping (Double, String) -> Void, finished: @escaping () -> Void) {
        stopFlyThrough(notify: false)
        let path = FlyPath(req)
        guard path.points.count >= 2 else { finished(); return }
        let h0 = FlyPath.bearing(path.points[0], path.points[min(20, path.points.count - 1)])
        let state = FlyThroughState(path: path, heading: h0, progress: progress, finished: finished)
        fly = state
        // The normal zoom floor (1.2 km) would hold a chase camera far back.
        mapView.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 150, maxCenterCoordinateDistance: CameraPresets.maxDistanceM)
        let pin = RoutePinAnnotation(kind: .flyer, coordinate: path.points[0].clCoordinate)
        flyerPin = pin
        mapView.addAnnotation(pin)
        // Swoop to the start, then hand over to the frame timer.
        let cam = flyCamera(at: path.points[0], heading: h0)
        mapView.setCamera(cam, animated: true)
        progress(0, path.labels.first ?? "")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self, weak state] in
            guard let self, let state, self.fly === state else { return }
            state.lastTick = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.flyTick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            state.timer = timer
        }
    }

    func setFlyThroughPaused(_ paused: Bool) {
        guard let f = fly else { return }
        f.paused = paused
        f.lastTick = CACurrentMediaTime()
    }

    func stopFlyThrough() { stopFlyThrough(notify: true) }

    private func stopFlyThrough(notify: Bool) {
        guard let f = fly else { return }
        f.timer?.invalidate()
        fly = nil
        mapView.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: CameraPresets.minDistanceM, maxCenterCoordinateDistance: CameraPresets.maxDistanceM)
        if let p = flyerPin { mapView.removeAnnotation(p); flyerPin = nil }
        if notify { f.finished() }
    }

    private func flyTick() {
        guard let f = fly else { return }
        let now = CACurrentMediaTime()
        let dt = min(now - f.lastTick, 0.1)
        f.lastTick = now
        if f.paused { return }
        f.t += dt
        let path = f.path
        if f.t >= path.duration {
            f.progress(1, path.labels.last ?? "")
            stopFlyThrough(notify: true)
            return
        }
        let i = path.index(at: f.t)
        let j = min(i + 1, path.points.count - 1)
        let span = max(path.times[j] - path.times[i], 1e-6)
        let frac = min(max((f.t - path.times[i]) / span, 0), 1)
        let a = path.points[i], b = path.points[j]
        let here = GeoCoordinate(lat: a.lat + (b.lat - a.lat) * frac, lon: a.lon + (b.lon - a.lon) * frac,
                                 ele: a.ele.flatMap { ea in b.ele.map { ea + ($0 - ea) * frac } })
        // Look ~150 m ahead along the path; ease the heading so turns don't jerk the camera.
        let ahead = path.points[min(i + 18, path.points.count - 1)]
        if here.distance(to: ahead) > 5 {
            let target = FlyPath.bearing(here, ahead)
            var delta = (target - f.heading).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
            f.heading = (f.heading + delta * min(1, dt * 1.6) + 360).truncatingRemainder(dividingBy: 360)
        }
        flyerPin?.coordinate = here.clCoordinate
        // MapKit only re-renders overlays once the camera settles, so instead of a new camera
        // every frame, hand it one animated move per keyframe (overlays stay drawn mid-flight).
        let keyframe = Double(ProcessInfo.processInfo.environment["HT_FLY_KEYFRAME"] ?? "") ?? 1.0
        if keyframe <= 0 {
            mapView.camera = flyCamera(at: here, heading: f.heading)
        } else if now - f.lastKeyframe >= keyframe {
            f.lastKeyframe = now
            // Aim where we'll be at the end of this keyframe.
            let k = path.index(at: min(f.t + keyframe, path.duration))
            let target = path.points[k]
            let cam = flyCamera(at: target, heading: f.heading)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = keyframe
                ctx.timingFunction = CAMediaTimingFunction(name: .linear)
                ctx.allowsImplicitAnimation = true
                mapView.animator().camera = cam
            }
        }
        f.progress(f.t / path.duration, path.labels[i])
    }

    var isFlying: Bool { fly != nil }

    /// Chase camera behind `p`, looking along `heading`.
    ///
    /// MapKit places the camera relative to a flat plane, but drapes the 3D terrain at its real
    /// height, so looking "at" a point on a slope frames it too low on screen. Measured (2026-11-16,
    /// Gunbarrel at 1.8 km / 58°): the plane sits near the terrain height under the eye, which is
    /// uphill of a skier going down. So aim at where the eye→skier ray meets that plane instead.
    func flyCamera(at p: GeoCoordinate, heading: Double) -> MKMapCamera {
        let env = ProcessInfo.processInfo.environment
        let dist = Double(env["HT_FLY_DIST"] ?? "") ?? Self.flyDistanceM
        let pitch = Double(env["HT_FLY_PITCH"] ?? "") ?? Self.flyPitch
        let gain = Double(env["HT_FLY_GAIN"] ?? "") ?? 1
        let h = heading * .pi / 180, pr = pitch * .pi / 180
        let mPerLon = 111_320 * cos(p.lat * .pi / 180), mPerLat = 110_574.0
        func offset(_ c: GeoCoordinate, _ m: Double) -> GeoCoordinate {
            GeoCoordinate(lat: c.lat + m * cos(h) / mPerLat, lon: c.lon + m * sin(h) / mPerLon)
        }
        let eyeGround = offset(p, -dist * sin(pr))
        var center = p
        if let e = p.ele ?? groundElevation(near: p), let z = groundElevation(near: eyeGround) {
            let dh = (e - z) * gain                      // negative when the skier is below the eye's ground
            center = offset(p, dh * tan(pr))
        }
        return MKMapCamera(lookingAtCenter: center.clCoordinate, fromDistance: dist, pitch: pitch, heading: heading)
    }

}
