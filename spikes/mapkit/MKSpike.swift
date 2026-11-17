// SkiLo — MapKit spike variant B: MKMapView (AppKit) inside SwiftUI via NSViewRepresentable.
// Gives mapViewDidFinishLoadingMap / mapViewDidFinishRenderingMap timing (SwiftUI Map has no such
// callback), MKPolyline overlays with MKPolylineRenderer, NSClickGestureRecognizer picking, and an
// in-process probe of MapKit's pitch clamp vs camera distance.

import SwiftUI
import MapKit
import AppKit

final class TrailPolyline: MKPolyline {
    var trailID: Int64 = 0; var name = ""; var difficulty: Difficulty = .unknown; var isHalo = false; var isSelected = false
}
final class LiftPolyline: MKPolyline { var kind = "" }

func nsColor(_ d: Difficulty) -> NSColor {
    switch d {
    case .easy:         return NSColor(red: 0.05, green: 0.80, blue: 0.25, alpha: 1)
    case .intermediate: return NSColor(red: 0.15, green: 0.50, blue: 1.00, alpha: 1)
    case .advanced, .expert: return .black
    case .unknown:      return .orange
    }
}

final class MKSpikeController: NSObject, MKMapViewDelegate, ObservableObject {
    let data: ResortData
    let mapView = MKMapView()
    @Published var status = ""
    @Published var selectedName: String? = nil
    @Published var cameraDesc = ""
    var selectedOverlays: [TrailPolyline] = []
    var loadedAt: Date?, firstRenderAt: Date?, fullyRenderedAt: Date?
    var renderCallbacks = 0, regionCallbacks = 0
    var scriptStarted = false
    var probeResults: [String] = []

    init(data: ResortData) {
        self.data = data
        super.init()
        mapView.delegate = self
        let cfg = MKHybridMapConfiguration(elevationStyle: Config.elevationMode == "flat" ? .flat : .realistic)
        cfg.pointOfInterestFilter = .excludingAll
        mapView.preferredConfiguration = cfg
        mapView.showsCompass = false; mapView.showsZoomControls = false; mapView.showsPitchControl = false
        let interact = Config.stayOpen // scripted runs: ignore stray external mouse/scroll events
        mapView.isPitchEnabled = interact; mapView.isRotateEnabled = interact; mapView.isZoomEnabled = interact; mapView.isScrollEnabled = interact
        for l in data.lifts { let o = LiftPolyline(coordinates: l.coords, count: l.coords.count); o.kind = l.kind; mapView.addOverlay(o) }
        for t in data.trails { let o = make(t); o.isHalo = true; mapView.addOverlay(o) }
        for t in data.trails { mapView.addOverlay(make(t)) }
        mapView.camera = MKMapCamera(lookingAtCenter: data.center, fromDistance: Config.distance, pitch: Config.pitch, heading: Config.heading)
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        mapView.addGestureRecognizer(click)
        log("MKMapView configured: \(mapView.overlays.count) overlays, isFlipped=\(mapView.isFlipped), camera pitch right after set = \(mapView.camera.pitch)")
    }

    private func make(_ t: Trail) -> TrailPolyline {
        let o = TrailPolyline(coordinates: t.coords, count: t.coords.count)
        o.trailID = t.id; o.name = t.name; o.difficulty = t.difficulty
        return o
    }

    /// Projection in the map view's own coordinate space (MKMapView is flipped on macOS: top-left origin).
    func project(_ c: CLLocationCoordinate2D) -> CGPoint? {
        let p = mapView.convert(c, toPointTo: mapView)
        if p.x.isNaN || p.y.isNaN { return nil }
        return mapView.isFlipped ? p : CGPoint(x: p.x, y: mapView.bounds.height - p.y)
    }

    @objc func handleClick(_ gr: NSClickGestureRecognizer) {
        var p = gr.location(in: mapView)
        if !mapView.isFlipped { p.y = mapView.bounds.height - p.y }
        _ = pick(at: p, source: "click")
    }

    @discardableResult
    func pick(at p: CGPoint, source: String) -> PickResult? {
        let t0 = Date()
        let r = pickTrail(at: p, trails: data.trails, bounds: mapView.bounds, threshold: 14) { self.project($0) }
        let us = Int(Date().timeIntervalSince(t0) * 1_000_000)
        select(name: r?.trail.name)
        status = r.map { "selected \"\($0.trail.name)\" [\($0.trail.difficulty.rawValue)] way \($0.trail.id) (\(Int($0.distancePts)) pt, pick \(us) µs)" }
            ?? "\(source) at \(Int(p.x)),\(Int(p.y)) hit nothing (pick \(us) µs)"
        log("MK-\(source.uppercased()) " + status)
        return r
    }

    /// Highlight = remove old highlight overlays, add fresh yellow overlays for every way sharing the name,
    /// above everything else. (Mutating an existing MKPolylineRenderer + setNeedsDisplay also works but
    /// cannot change z-order; re-adding is the robust way.)
    func select(name: String?) {
        mapView.removeOverlays(selectedOverlays); selectedOverlays = []
        selectedName = name
        guard let name else { return }
        for t in data.trails where t.name == name {
            let o = make(t); o.isSelected = true; selectedOverlays.append(o)
        }
        mapView.addOverlays(selectedOverlays, level: .aboveLabels)
    }

    // MARK: MKMapViewDelegate
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let t = overlay as? TrailPolyline {
            let r = MKPolylineRenderer(polyline: t)
            if t.isSelected { r.strokeColor = .systemYellow; r.lineWidth = 8 }
            else if t.isHalo { r.strokeColor = NSColor.white.withAlphaComponent(0.9); r.lineWidth = 5 }
            else { r.strokeColor = nsColor(t.difficulty); r.lineWidth = 3; if t.difficulty.isDouble { r.lineDashPattern = [7, 4]; r.lineCap = .butt } }
            return r
        }
        if let l = overlay as? LiftPolyline {
            let r = MKPolylineRenderer(polyline: l)
            if l.kind == "gondola" || l.kind == "cable_car" { r.strokeColor = .systemRed; r.lineWidth = 2.5 }
            else { r.strokeColor = NSColor(white: 0.85, alpha: 1); r.lineWidth = 1.5; if l.kind != "chair_lift" { r.lineDashPattern = [3, 3] } }
            return r
        }
        return MKOverlayRenderer(overlay: overlay)
    }
    func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
        if loadedAt == nil { loadedAt = Date(); log("mapViewDidFinishLoadingMap") }
    }
    func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) { log("mapViewDidFailLoadingMap: \(error)") }
    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        renderCallbacks += 1
        if firstRenderAt == nil { firstRenderAt = Date(); log("mapViewDidFinishRenderingMap (first) fullyRendered=\(fullyRendered)") }
        if fullyRendered && fullyRenderedAt == nil { fullyRenderedAt = Date(); log("mapViewDidFinishRenderingMap fullyRendered=true") }
    }
    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        regionCallbacks += 1
        let c = mapView.camera
        cameraDesc = String(format: "dist %.0f m  heading %.0f  pitch %.0f  alt %.0f", c.centerCoordinateDistance, c.heading, c.pitch, c.altitude)
        if regionCallbacks <= 3 { log("regionDidChange: \(cameraDesc)") }
    }

    // MARK: Pitch clamp probe: set pitch 75 at several distances, read back what MapKit kept.
    func runPitchProbe(_ distances: [Double], then done: @escaping () -> Void) {
        guard let d = distances.first else {
            mapView.setCamera(MKMapCamera(lookingAtCenter: data.center, fromDistance: Config.distance, pitch: Config.pitch, heading: Config.heading), animated: false)
            log("PITCH PROBE (requested 75°): " + probeResults.joined(separator: ", ") + " | restored main camera, pitch now \(Int(mapView.camera.pitch))")
            done(); return
        }
        mapView.setCamera(MKMapCamera(lookingAtCenter: data.center, fromDistance: d, pitch: 75, heading: Config.heading), animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.probeResults.append("\(Int(d))m→\(Int(self.mapView.camera.pitch.rounded()))°")
            self.runPitchProbe(Array(distances.dropFirst()), then: done)
        }
    }
}

struct MKMapRepresentable: NSViewRepresentable {
    let controller: MKSpikeController
    func makeNSView(context: Context) -> MKMapView { controller.mapView }
    func updateNSView(_ nsView: MKMapView, context: Context) {}
}

struct MKContentView: View {
    @StateObject var ctl: MKSpikeController = {
        let d = (try? ResortData.load(path: Config.jsonPath)) ?? ResortData()
        log("loaded \(d.trails.count) pistes, \(d.lifts.count) lifts")
        return MKSpikeController(data: d)
    }()

    var body: some View {
        MKMapRepresentable(controller: ctl)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Heavenly — MKMapView spike (hybrid, elevation \(Config.elevationMode))").font(.headline)
                    Text(ctl.status).font(.caption)
                    Text(ctl.cameraDesc).font(.caption.monospaced())
                    if let s = ctl.selectedName { Text("Selected: \(s)").font(.title3.bold()).foregroundStyle(.yellow) }
                }
                .padding(10).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white).padding(12)
            }
            .onAppear {
                log("MKContentView onAppear")
                NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
                if !ctl.scriptStarted { ctl.scriptStarted = true; runScript() }
            }
    }

    func runScript() {
        let out = Config.outDir + "/mk"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let tag = "mk_\(Config.elevationMode)"
        // Let the first render happen, then probe pitch clamps, then the normal screenshot flow.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            ctl.runPitchProbe([20000, 11000, 8000, 5000, 3000, 2000, 1200, 700, 400, 200]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + Config.delay) {
                    guard let w = NSApp.windows.first else { log("no window"); exit(2) }
                    let mv = ctl.mapView
                    log("camera at screenshot time: \(ctl.cameraDesc); mapView bounds \(mv.bounds) frame-in-window \(mv.convert(mv.bounds, to: nil)) window \(w.frame)")
                    let p1 = "\(out)/shot1_\(tag)_initial.png"
                    captureWindow(w, to: p1); log("screenshot 1 -> \(p1)")
                    // visible target near the center
                    let b = mv.bounds.insetBy(dx: 120, dy: 120), c = CGPoint(x: mv.bounds.midX, y: mv.bounds.midY)
                    var best: (Trail, CGPoint, CGFloat)? = nil
                    for t in ctl.data.trails where !t.name.hasPrefix("(unnamed") && t.coords.count >= 3 {
                        if let p = ctl.project(t.coords[t.coords.count / 2]), b.contains(p) {
                            let d = hypot(p.x - c.x, p.y - c.y); if best == nil || d < best!.2 { best = (t, p, d) }
                        }
                    }
                    if let (trail, pt, _) = best {
                        let r = ctl.pick(at: pt, source: "function-test")
                        log("MK PICK-FUNCTION TEST: expected \"\(trail.name)\" -> \(r?.trail.name ?? "nil") => \(r?.trail.name == trail.name ? "PASS" : "FAIL")")
                        ctl.select(name: nil)
                        // synthetic click: map-view point -> window point (AppKit, bottom-left origin)
                        let viewPt = mv.isFlipped ? pt : CGPoint(x: pt.x, y: mv.bounds.height - pt.y)
                        let winPt = mv.convert(viewPt, to: nil)
                        sendSyntheticClick(window: w, windowPoint: winPt)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            let ok = ctl.selectedName == trail.name
                            log("MK SYNTHETIC-CLICK TEST (NSClickGestureRecognizer): expecting \"\(trail.name)\" -> \(ctl.selectedName ?? "nil") => \(ok ? "PASS" : "FAIL")")
                            if !ok { ctl.select(name: trail.name) }
                        }
                    } else { log("MK PICK TEST: no visible target") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        let p2 = "\(out)/shot2_\(tag)_selected.png"
                        captureWindow(w, to: p2); log("screenshot 2 -> \(p2)")
                        drapeAnalysis(pngPath: p1, window: w, trails: ctl.data.trails, bounds: mv.bounds) { ctl.project($0) }
                        log("done. renderCallbacks \(ctl.renderCallbacks), regionCallbacks \(ctl.regionCallbacks); loaded at \(ctl.loadedAt.map { String(format: "%.2fs", $0.timeIntervalSince(Config.launch)) } ?? "never"), first render \(ctl.firstRenderAt.map { String(format: "%.2fs", $0.timeIntervalSince(Config.launch)) } ?? "never"), fully rendered \(ctl.fullyRenderedAt.map { String(format: "%.2fs", $0.timeIntervalSince(Config.launch)) } ?? "never")")
                        logResourceUsage()
                        if !Config.stayOpen { exit(0) }
                    }
                }
            }
        }
    }
}

@main
struct MKSpikeApp: App {
    init() { log("main start (MKMapView variant); pid \(getpid()); elevation \(Config.elevationMode) delay \(Config.delay)s") }
    var body: some Scene {
        WindowGroup("Heavenly MKMapView Spike") { MKContentView() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1400, height: 900)
    }
}
