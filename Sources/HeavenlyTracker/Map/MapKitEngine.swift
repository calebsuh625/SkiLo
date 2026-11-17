// MapKitEngine — DESIGN §8 implementation of the MapEngine contract on MKMapView.
//
// WP3.1 findings (settled by screenshot in the app itself, 2026-11-02; the spike binary always uses
// hybrid, so the comparison was run with HT_SAT_CONFIG=imagery|hybrid at the California preset):
//  (a) MKImageryMapConfiguration(elevationStyle: .realistic) DOES render 3D relief and keeps pitch
//      on macOS, with no street/POI labels on the mountain → `.satellite` ships with imagery.
//  (b) No gray sky grid at 2.5 km / 60° for any close preset. But MapKit clamped 60° → 35° at the
//      requested 2.9 km (view ~700 pt wide beside the inspector), so the engine steps the distance
//      down ×0.85 (≤ 3 times, never below 1,200 m) until the pitch is kept: CA/NV settle at
//      2,465 m / 60°, Mott/Killebrew at 2,349 m / 60°. The camera actually kept is reported.
//      The gray grid DID appear when the California view looked west toward town/lake (flat
//      untextured mesh), which is why the CA preset was retuned to look ESE (CameraPresets).
//  (c) Discovered: `convert(_:toPointTo:)` ignores realistic terrain (~65 pt error at the close
//      presets) and `.aboveLabels` overlays are not draped (hidden under terrain). Fixes: terrain-
//      aware projection calibrated with invisible annotation probes (MapKitEngine+Probes/+Picking),
//      selection overlays added last at `.aboveRoads`.
//
// Known limitations (accepted for V1, DESIGN §1.4): MapKit exposes no terrain occlusion, so
// `project()` returns nil only for off-screen points and badges may draw through ridges.
// The engine persists nothing; it is stateless beyond the view and its caches.
import AppKit
import MapKit
import QuartzCore

extension GeoCoordinate {
    var clCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

/// MKMapView that forwards hover events (NSTrackingArea, DESIGN §8.3).
final class EngineMapView: MKMapView {
    var onMouseMoved: ((NSEvent) -> Void)?
    var onMouseExited: (() -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); onMouseMoved?(event) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onMouseExited?() }
}

@MainActor
final class MapKitEngine: NSObject, MapEngine, MKMapViewDelegate {
    static let displayName = "Apple Maps (MapKit)"
    /// WP3.1 (a): true = `MKImageryMapConfiguration(elevationStyle: .realistic)` for `.satellite`,
    /// false = `MKHybridMapConfiguration(elevationStyle: .realistic)`. `HT_SAT_CONFIG=imagery|hybrid`
    /// overrides it for the comparison screenshot.
    static var satelliteUsesImagery: Bool {
        switch ProcessInfo.processInfo.environment["HT_SAT_CONFIG"] {
        case "imagery": return true
        case "hybrid": return false
        default: return defaultSatelliteUsesImagery
        }
    }
    static let defaultSatelliteUsesImagery = true

    var capabilities: MapEngineCapabilities { [.terrain3D, .pitch, .hover, .badges, .animateStyle, .labels] }
    var supportedBaseStyles: [MapBaseStyle] { MapBaseStyle.allCases }
    weak var delegate: (any MapEngineDelegate)?

    // View (created lazily so SwiftUI's discarded @State initial values cost nothing).
    private var _mapView: EngineMapView?
    var mapView: EngineMapView {
        if let m = _mapView { return m }
        let m = makeMapView(); _mapView = m; return m
    }

    // Scene + caches
    var scene: MapScene?
    var trailIndex: [Trail.ID: TrailGeometry] = [:]
    var trailOverlays: [Trail.ID: [TrailOverlay]] = [:]
    var selectionOverlays: [TrailOverlay] = []
    var staticOverlays: [StaticOverlay] = []
    var renderers: [ObjectIdentifier: MKPolylineRenderer] = [:]
    var lastStyles: [Trail.ID: TrailStyle] = [:]
    var selectedID: Trail.ID?
    var baseStyle: MapBaseStyle = .satellite
    var widthScale: Double = 1
    var flashing: Set<Trail.ID> = []
    var projectionCache: ProjectionCache?
    var badgeAnnotations: [Trail.ID: BadgeAnnotation] = [:]
    var labelAnnotation: LabelAnnotation?
    var probes: [ProbeAnnotation] = []

    // Hover / picking
    var pendingHover: DispatchWorkItem?
    var lastHoverTime: TimeInterval = 0
    var lastHoverID: Trail.ID?
    var lastPickUs: Double = 0
    let verboseTiming = ProcessInfo.processInfo.environment["HT_SCREENSHOT"] != nil || ProcessInfo.processInfo.environment["HT_MAP_LOG"] != nil

    // Camera
    private var pitchFix: (state: CameraState, attempts: Int)?
    private var reportedFailure = false

    func makeView() -> NSView { mapView }

    private func makeMapView() -> EngineMapView {
        let m = EngineMapView()
        m.preferredConfiguration = Self.configuration(for: baseStyle)
        m.pointOfInterestFilter = .excludingAll
        m.showsCompass = true
        m.showsPitchControl = false
        m.showsZoomControls = false
        m.isZoomEnabled = true; m.isScrollEnabled = true; m.isRotateEnabled = true; m.isPitchEnabled = true
        m.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: CameraPresets.minDistanceM,
                                                       maxCenterCoordinateDistance: CameraPresets.maxDistanceM)
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        m.addGestureRecognizer(click)
        m.onMouseMoved = { [weak self] e in self?.handleMouseMoved(e) }
        m.onMouseExited = { [weak self] in self?.handleMouseExited() }
        // Delegate last: MapKit calls regionDidChange synchronously from the setters above, and
        // the delegate reads `mapView`, which is not assigned until this returns.
        m.delegate = self
        return m
    }

    static func configuration(for style: MapBaseStyle) -> MKMapConfiguration {
        switch style {
        case .satellite:
            if satelliteUsesImagery { return MKImageryMapConfiguration(elevationStyle: .realistic) }
            let c = MKHybridMapConfiguration(elevationStyle: .realistic)
            c.pointOfInterestFilter = .excludingAll
            return c
        case .terrain:
            let c = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
            c.pointOfInterestFilter = .excludingAll
            return c
        case .outline:
            let c = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            c.pointOfInterestFilter = .excludingAll
            return c
        }
    }

    // MARK: Inputs

    func load(scene: MapScene) {
        let m = mapView
        m.removeOverlays(m.overlays)
        m.removeAnnotations(m.annotations)
        renderers = [:]; trailOverlays = [:]; selectionOverlays = []; staticOverlays = []
        badgeAnnotations = [:]; labelAnnotation = nil; projectionCache = nil
        self.scene = scene
        trailIndex = Dictionary(scene.trails.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let region = MKCoordinateRegion(scene.bounds.padded(byMetres: 4_000).mkRect)
        m.cameraBoundary = MKMapView.CameraBoundary(coordinateRegion: region)

        // Order (z within one level = add order): boundary, connectors, lifts, casings, strokes.
        for b in scene.boundary { staticOverlays.append(.make(b, role: .boundary)) }
        for c in scene.connectors { staticOverlays.append(.make(c, role: .connector)) }
        for l in scene.lifts { staticOverlays.append(.make(l.polyline, role: .liftCasing, liftKind: l.kind)) }
        for l in scene.lifts { staticOverlays.append(.make(l.polyline, role: .lift, liftKind: l.kind)) }
        var casings: [TrailOverlay] = [], strokes: [TrailOverlay] = []
        for t in scene.trails {
            for (i, pl) in t.polylines.enumerated() {
                let c = TrailOverlay.make(pl, trailID: t.id, wayIndex: i, role: .casing)
                let s = TrailOverlay.make(pl, trailID: t.id, wayIndex: i, role: .stroke)
                casings.append(c); strokes.append(s)
                trailOverlays[t.id, default: []].append(contentsOf: [c, s])
            }
        }
        probes = makeProbes(for: scene)
        m.addAnnotations(probes)
        m.addOverlays(staticOverlays, level: .aboveRoads)
        m.addOverlays(casings, level: .aboveRoads)
        m.addOverlays(strokes, level: .aboveRoads)
        let sel = selectedID; selectedID = nil
        let styles = lastStyles; lastStyles = [:]
        apply(styles: styles)
        setSelection(sel)
    }

    func apply(styles: [Trail.ID: TrailStyle]) {
        let t0 = CACurrentMediaTime()
        var changed = 0
        for (id, s) in styles where lastStyles[id] != s {
            let old = lastStyles[id]
            lastStyles[id] = s
            changed += 1
            restyle(id)
            if old?.badge != s.badge { updateBadge(id, old: old?.badge ?? .none) }
            if id == selectedID, old?.label != s.label { updateLabel() }
        }
        for id in lastStyles.keys where styles[id] == nil {
            lastStyles[id] = nil; restyle(id); updateBadge(id, old: .none); changed += 1
        }
        if verboseTiming && changed > 0 {
            NSLog("MapKitEngine.apply(styles:) %d entries, %d changed, %.3f ms", styles.count, changed, (CACurrentMediaTime() - t0) * 1000)
        }
    }

    func setSelection(_ id: Trail.ID?) {
        guard id != selectedID else { return }
        let m = mapView
        if !selectionOverlays.isEmpty {
            m.removeOverlays(selectionOverlays)
            for o in selectionOverlays { renderers[ObjectIdentifier(o)] = nil }
            selectionOverlays = []
        }
        selectedID = id
        if let id, let t = trailIndex[id] {
            var glow: [TrailOverlay] = [], casing: [TrailOverlay] = [], stroke: [TrailOverlay] = []
            for (i, pl) in t.polylines.enumerated() {
                glow.append(.make(pl, trailID: id, wayIndex: i, role: .glow, isSelectionCopy: true))
                casing.append(.make(pl, trailID: id, wayIndex: i, role: .casing, isSelectionCopy: true))
                stroke.append(.make(pl, trailID: id, wayIndex: i, role: .stroke, isSelectionCopy: true))
            }
            selectionOverlays = glow + casing + stroke
            // .aboveRoads, not .aboveLabels: with realistic elevation, .aboveLabels overlays are not
            // draped and end up hidden under the 3D terrain (verified by screenshot 2026-11-02).
            // Added last, so they sit on top of every other overlay of the same level.
            m.addOverlays(selectionOverlays, level: .aboveRoads)
        }
        updateLabel()
    }

    func setBaseStyle(_ style: MapBaseStyle) {
        guard style != baseStyle || _mapView == nil else { return }
        baseStyle = style
        if style != .outline { reportedFailure = false }
        mapView.preferredConfiguration = Self.configuration(for: style)
        restyleStatic()
    }

    func setCamera(_ preset: CameraPreset, animated: Bool) {
        guard let scene else { return }
        let s = CameraPresets.state(for: preset, scene: scene, viewSize: mapView.bounds.size, current: currentCamera())
        setCamera(s, animated: animated)
    }

    func setCamera(_ state: CameraState, animated: Bool) {
        pitchFix = (state, 0)
        mapView.setCamera(Self.mkCamera(state), animated: animated)
        if !animated { checkPitch() }
    }

    static func mkCamera(_ s: CameraState) -> MKMapCamera {
        MKMapCamera(lookingAtCenter: s.center.clCoordinate, fromDistance: s.distanceM, pitch: CGFloat(s.pitchDeg), heading: s.headingDeg)
    }

    /// MapKit silently clamps pitch by distance; step the distance down until it keeps the
    /// requested pitch (outline is flat by design and is never fixed up).
    private func checkPitch() {
        guard var fix = pitchFix else { return }
        let kept = Double(mapView.camera.pitch)
        guard baseStyle != .outline, kept < fix.state.pitchDeg - 1, fix.attempts < 3,
              fix.state.distanceM * 0.85 >= CameraPresets.minDistanceM else { pitchFix = nil; return }
        fix.attempts += 1
        let had = fix.state.distanceM
        fix.state.distanceM = had * 0.85
        pitchFix = fix
        if verboseTiming { NSLog("MapKitEngine pitch fix-up #%d: requested %.0f° at %.0f m, kept %.1f°, retrying at %.0f m", fix.attempts, fix.state.pitchDeg, had, kept, fix.state.distanceM) }
        mapView.setCamera(Self.mkCamera(fix.state), animated: false)
        // A non-animated set from inside a region callback does not always call back again:
        // re-check and report the camera MapKit actually kept on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pitchFix != nil else { return }
            self.checkPitch()
            if self.pitchFix == nil || self.pitchFix?.attempts == 3 {
                if self.verboseTiming { let c = self.currentCamera(); NSLog("MapKitEngine camera kept after fix-up: dist %.0f m pitch %.1f", c.distanceM, c.pitchDeg) }
                self.delegate?.mapEngine(self, cameraDidChange: self.currentCamera())
            }
        }
    }

    func animateStatusChange(_ id: Trail.ID, to badge: TrailStyle.Badge) {
        if badge == .done {
            flashing.insert(id); restyle(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.flashing.remove(id); self.restyle(id)
            }
        }
        // The badge annotation is (re)created by apply(styles:); pop it once its view exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let a = self.badgeAnnotations[id], let v = self.mapView.view(for: a) else { return }
            Self.pop(v)
        }
    }

    // MARK: Queries

    func currentCamera() -> CameraState {
        let c = mapView.camera
        return CameraState(center: GeoCoordinate(lat: c.centerCoordinate.latitude, lon: c.centerCoordinate.longitude),
                           distanceM: c.centerCoordinateDistance, headingDeg: c.heading, pitchDeg: Double(c.pitch))
    }

    func project(_ c: GeoCoordinate) -> CGPoint? {
        _ = projected()   // refreshes the per-camera terrain context
        guard let k = projectionCache?.context, let p = projectTerrain(c, context: k), mapView.bounds.contains(p) else { return nil }
        return p
    }

    func hitTest(_ point: CGPoint) -> Trail.ID? {
        let t0 = CACurrentMediaTime()
        let r = Picking.nearest(to: point, in: projected(), bounds: mapView.bounds, threshold: Picking.defaultThreshold)
        lastPickUs = (CACurrentMediaTime() - t0) * 1_000_000
        return r?.id
    }

    // MARK: MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer { renderer(for: overlay) }
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? { annotationView(for: annotation) }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        guard _mapView != nil else { return }
        let cam = currentCamera()
        let scale = (min(max(11_000 / max(cam.distanceM, 1), 1), 2) * 5).rounded() / 5   // 0.2 steps: fewer full-map redraws while zooming
        if abs(scale - widthScale) > 0.01 {
            widthScale = scale
            for id in trailOverlays.keys { restyle(id) }
            restyleStatic()
        }
        if verboseTiming {
            NSLog("MapKitEngine camera: center %.4f, %.4f  dist %.0f m  heading %.0f  pitch %.1f  (width scale %.2f)",
                  cam.center.lat, cam.center.lon, cam.distanceM, cam.headingDeg, cam.pitchDeg, widthScale)
        }
        if pitchFix != nil { checkPitch() }
        guard scene != nil else { return }
        delegate?.mapEngine(self, cameraDidChange: cam)
    }

    func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
        delegate?.mapEngine(self, didFinishLoading: true, error: nil)
    }

    func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
        NSLog("MapKitEngine: mapViewDidFailLoadingMap: %@", "\(error)")
        guard !reportedFailure else { return }
        reportedFailure = true
        setBaseStyle(.outline)
        delegate?.mapEngine(self, didFinishLoading: false, error: error)
    }
}

extension GeoBounds {
    var mkRect: MKMapRect {
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: maxLat, longitude: minLon))
        let b = MKMapPoint(CLLocationCoordinate2D(latitude: minLat, longitude: maxLon))
        return MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
