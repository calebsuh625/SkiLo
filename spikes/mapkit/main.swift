// SkiLo — MapKit 3D terrain feasibility spike (macOS, SwiftUI Map).
// Build: ./build.sh   Run: ./run.sh [realistic|flat] [delaySeconds]
// Loads the raw OSM Overpass JSON, draws all downhill pistes + lifts as MapPolylines over
// .hybrid(elevation: .realistic), pitched camera, click-to-select via MapReader + nearest-segment
// math, then self-screenshots, runs a synthetic-click selection test, and exits.

import SwiftUI
import MapKit
import AppKit

// MARK: - View model

@MainActor
final class SpikeModel: ObservableObject {
    @Published var data = ResortData()
    @Published var selectedName: String? = nil
    @Published var selectedWayID: Int64? = nil
    @Published var nativeSelection: Int64? = nil   // SwiftUI Map(selection:) + .tag() experiment
    @Published var status = "loading…"
    @Published var lastTap: CGPoint? = nil
    @Published var cameraDesc = ""
    var mapBounds: CGRect = .zero
    var proxy: MapProxy? = nil
    var firstCameraCallback: Date? = nil
    var lastCameraCallback: Date? = nil
    var cameraCallbacks = 0
    var scriptStarted = false

    init() {
        do {
            let t0 = Date()
            data = try ResortData.load(path: Config.jsonPath)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let verts = data.trails.reduce(0) { $0 + $1.coords.count }
            status = "loaded \(data.trails.count) pistes (\(verts) vertices), \(data.lifts.count) lifts in \(ms) ms"
            log(status)
            var counts: [Difficulty: Int] = [:]
            for t in data.trails { counts[t.difficulty, default: 0] += 1 }
            log("difficulty counts: " + Difficulty.allCases.map { "\($0.rawValue)=\(counts[$0] ?? 0)" }.joined(separator: " "))
            log("center \(data.center.latitude), \(data.center.longitude)")
        } catch {
            status = "LOAD FAILED: \(error)"
            log(status)
        }
    }

    func handleTap(_ p: CGPoint) {
        lastTap = p
        guard let proxy else { log("tap at \(p) but no proxy"); return }
        let t0 = Date()
        let r = pickTrail(at: p, trails: data.trails, bounds: mapBounds, threshold: 14) { proxy.convert($0, to: .local) }
        let us = Int(Date().timeIntervalSince(t0) * 1_000_000)
        if let r {
            selectedName = r.trail.name; selectedWayID = r.trail.id
            status = "selected \"\(r.trail.name)\" [\(r.trail.difficulty.rawValue)] way \(r.trail.id) (\(Int(r.distancePts)) pt away, pick took \(us) µs)"
        } else {
            selectedName = nil; selectedWayID = nil
            let coord = proxy.convert(p, from: .local)
            status = "tap at \(Int(p.x)),\(Int(p.y)) hit nothing (coord \(coord.map { "\($0.latitude),\($0.longitude)" } ?? "nil")); pick took \(us) µs"
        }
        log("TAP " + status)
    }
}

// MARK: - Map view

struct SpikeMapView: View {
    @ObservedObject var model: SpikeModel
    @State private var position: MapCameraPosition = .camera(
        MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: 38.9397, longitude: -119.912),
                  distance: Config.distance, heading: Config.heading, pitch: Config.pitch))

    @MapContentBuilder var content: some MapContent {
        // Lifts (under the trails)
        ForEach(model.data.lifts) { lift in
            if lift.isMajor {
                        MapPolyline(coordinates: lift.coords).stroke(Color.red, lineWidth: 2.5)
                    } else if lift.kind == "chair_lift" {
                        MapPolyline(coordinates: lift.coords).stroke(Color(white: 0.85), lineWidth: 1.5)
                    } else {
                        MapPolyline(coordinates: lift.coords)
                            .stroke(Color(white: 0.85), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    }
                }
                // Trail halos (white, under) so black runs read on dark imagery
                ForEach(model.data.trails) { t in
                    MapPolyline(coordinates: t.coords).stroke(Color.white.opacity(0.9), lineWidth: 5)
                }
                // Trail color by piste:difficulty; expert = dashed black ("double black")
                ForEach(model.data.trails) { t in
                    if t.difficulty.isDouble {
                        MapPolyline(coordinates: t.coords)
                            .stroke(t.difficulty.color, style: StrokeStyle(lineWidth: 3, lineCap: .butt, dash: [7, 4]))
                    } else {
                        MapPolyline(coordinates: t.coords).stroke(t.difficulty.color, lineWidth: 3).tag(t.id)
                    }
                }
                // Selected trail (all ways sharing the name), on top
                if let sel = model.selectedName {
                    ForEach(model.data.trails.filter { $0.name == sel }) { t in
                        MapPolyline(coordinates: t.coords).stroke(Color.yellow, lineWidth: 8)
                    }
                }
    }

    var style: MapStyle {
        let elev: MapStyle.Elevation = Config.elevationMode == "flat" ? .flat : .realistic
        switch Config.styleMode {
        case "imagery":  return .imagery(elevation: elev)
        case "standard": return .standard(elevation: elev, pointsOfInterest: .excludingAll)
        default:         return .hybrid(elevation: elev, pointsOfInterest: .excludingAll)
        }
    }

    var body: some View {
        MapReader { proxy in
            Group {
                if Config.nativeSelection {
                    Map(position: $position, interactionModes: Config.stayOpen ? .all : [], selection: $model.nativeSelection) { content }
                } else {
                    Map(position: $position, interactionModes: Config.stayOpen ? .all : []) { content } // scripted runs: ignore stray external mouse/scroll events
                }
            }
            .mapStyle(style)
            .mapControlVisibility(.hidden)
            .onTapGesture(count: 1, coordinateSpace: .local) { p in model.handleTap(p) }
            .onMapCameraChange(frequency: .continuous) { ctx in
                model.cameraCallbacks += 1
                model.lastCameraCallback = Date()
                if model.firstCameraCallback == nil {
                    model.firstCameraCallback = Date()
                    log("first onMapCameraChange: center=\(ctx.camera.centerCoordinate) dist=\(Int(ctx.camera.distance)) heading=\(Int(ctx.camera.heading)) pitch=\(Int(ctx.camera.pitch))")
                }
                model.cameraDesc = String(format: "dist %.0f m  heading %.0f  pitch %.0f", ctx.camera.distance, ctx.camera.heading, ctx.camera.pitch)
            }
            .background(GeometryReader { g in
                Color.clear.onAppear {
                    model.mapBounds = CGRect(origin: .zero, size: g.size)
                    log("map local bounds \(g.size), global frame \(g.frame(in: .global))")
                }
                .onChange(of: g.size) { _, s in model.mapBounds = CGRect(origin: .zero, size: s) }
            })
            .onAppear { model.proxy = proxy }
            .onChange(of: model.nativeSelection) { _, v in log("NATIVE Map(selection:) changed -> \(v.map(String.init) ?? "nil")") }
            .onChange(of: model.cameraCallbacks) { _, _ in model.proxy = proxy }
        }
    }
}

struct ContentView: View {
    @StateObject var model = SpikeModel()
    var body: some View {
        SpikeMapView(model: model)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Heavenly — MapKit 3D spike (\(Config.styleMode), elevation \(Config.elevationMode))").font(.headline)
                    Text(model.status).font(.caption)
                    Text(model.cameraDesc).font(.caption.monospaced())
                    if let s = model.selectedName { Text("Selected: \(s)").font(.title3.bold()).foregroundStyle(.yellow) }
                    HStack(spacing: 10) {
                        legend(.easy, "easy"); legend(.intermediate, "intermediate"); legend(.advanced, "advanced"); legend(.expert, "expert (dashed)")
                    }.font(.caption)
                }
                .padding(10)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
                .padding(12)
            }
            .onAppear {
                log("ContentView onAppear")
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                if !model.scriptStarted { model.scriptStarted = true; runScript() }
            }
    }

    func legend(_ d: Difficulty, _ label: String) -> some View {
        HStack(spacing: 3) { Capsule().fill(d.color).frame(width: 18, height: 5).overlay(Capsule().stroke(.white, lineWidth: 0.5)); Text(label) }
    }

    // MARK: Automated test script: screenshot → synthetic click → screenshot → drape check → exit
    func runScript() {
        let d = Config.delay
        let out = Config.outDir
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let tag = ProcessInfo.processInfo.environment["SPIKE_TAG"] ?? "\(Config.styleMode)_\(Config.elevationMode)"

        DispatchQueue.main.asyncAfter(deadline: .now() + d) {
            guard let w = NSApp.windows.first else { log("no window!"); exit(2) }
            log("window frame \(w.frame) contentView bounds \(w.contentView!.bounds) backingScale \(w.backingScaleFactor) windowNumber \(w.windowNumber)")
            log("camera at screenshot time: \(model.cameraDesc) (requested dist \(Int(Config.distance)) heading \(Int(Config.heading)) pitch \(Int(Config.pitch)))")
            let p1 = "\(out)/shot1_\(tag)_initial.png"
            captureWindow(w, to: p1)
            log("screenshot 1 -> \(p1)")

            // Projection sample: how do trail vertices project through the pitched camera?
            dumpProjectionSamples()

            // 1) Pure-function pick test on a known trail vertex (no UI involved)
            let target = chooseVisibleTarget()
            if let (trail, pt) = target, let proxy = model.proxy {
                let r = pickTrail(at: pt, trails: model.data.trails, bounds: model.mapBounds, threshold: 14) { proxy.convert($0, to: .local) }
                log("PICK-FUNCTION TEST: expected \"\(trail.name)\" way \(trail.id) at \(pt) -> got \(r.map { "\"\($0.trail.name)\" way \($0.trail.id) d=\(String(format: "%.1f", $0.distancePts))" } ?? "nil") => \(r?.trail.id == trail.id ? "PASS" : (r?.trail.name == trail.name ? "PASS (same name, different way)" : "FAIL"))")
                // 2) Synthetic click through AppKit event delivery → SwiftUI onTapGesture
                model.selectedName = nil; model.selectedWayID = nil
                syntheticClick(window: w, localPoint: pt)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let ok = model.selectedName == trail.name
                    log("SYNTHETIC-CLICK TEST: clicked \(pt) expecting \"\(trail.name)\" -> selectedName=\(model.selectedName ?? "nil") => \(ok ? "PASS" : "FAIL")")
                    if Config.nativeSelection { log("NATIVE-SELECTION TEST: Map(selection:) binding after click on tagged polyline (way \(trail.id)) = \(model.nativeSelection.map(String.init) ?? "nil") => \(model.nativeSelection == trail.id ? "FIRES for polylines" : "does NOT select polylines")") }
                    if !ok { // fall back to programmatic selection so shot 2 still shows highlight
                        model.selectedName = trail.name; model.selectedWayID = trail.id
                        log("fallback: programmatically selected \(trail.name)")
                    }
                }
            } else {
                log("PICK TEST: no visible target found (proxy=\(model.proxy != nil))")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let p2 = "\(out)/shot2_\(tag)_selected.png"
                captureWindow(w, to: p2)
                log("screenshot 2 -> \(p2)")
                drapeCheck(pngPath: p1, window: w)
                log("done. camera callbacks: \(model.cameraCallbacks) (last at \(model.lastCameraCallback.map { String(format: "%.2fs", $0.timeIntervalSince(Config.launch)) } ?? "never")); firstCameraCallback at \(model.firstCameraCallback.map { String(format: "%.2fs", $0.timeIntervalSince(Config.launch)) } ?? "never")")
                logResourceUsage()
                if !Config.stayOpen { exit(0) }
            }
        }
    }


    /// Pick a named trail vertex comfortably inside the viewport (prefer near the center).
    func chooseVisibleTarget() -> (Trail, CGPoint)? {
        guard let proxy = model.proxy else { return nil }
        let b = model.mapBounds.insetBy(dx: 120, dy: 120)
        let c = CGPoint(x: model.mapBounds.midX, y: model.mapBounds.midY)
        var best: (Trail, CGPoint, CGFloat)? = nil
        for t in model.data.trails where !t.name.hasPrefix("(unnamed") {
            guard t.coords.count >= 3 else { continue }
            let mid = t.coords[t.coords.count / 2]
            guard let p = proxy.convert(mid, to: .local), b.contains(p) else { continue }
            let d = hypot(p.x - c.x, p.y - c.y)
            if best == nil || d < best!.2 { best = (t, p, d) }
        }
        return best.map { ($0.0, $0.1) }
    }

    func dumpProjectionSamples() {
        guard let proxy = model.proxy else { return }
        var onScreen = 0, total = 0
        for t in model.data.trails { for c in t.coords { total += 1; if let p = proxy.convert(c, to: .local), model.mapBounds.contains(p) { onScreen += 1 } } }
        log("projection: \(onScreen)/\(total) trail vertices project inside the viewport")
        let c = model.data.center
        if let p = proxy.convert(c, to: .local) {
            log("center coord -> local \(p); round trip -> \(proxy.convert(p, from: .local).map { "\($0.latitude),\($0.longitude)" } ?? "nil")")
        }
        var rt: [CGFloat] = []
        for t in model.data.trails where t.coords.count > 2 {
            guard let p = proxy.convert(t.coords[1], to: .local), model.mapBounds.contains(p),
                  let c2 = proxy.convert(p, from: .local), let p2 = proxy.convert(c2, to: .local) else { continue }
            rt.append(hypot(p2.x - p.x, p2.y - p.y))
        }
        let rts = rt.sorted()
        if !rts.isEmpty { log(String(format: "round-trip coord->pt->coord->pt error over %d vertices: median %.1f pt, p90 %.1f pt, max %.1f pt", rts.count, rts[rts.count/2], rts[min(rts.count-1, rts.count*9/10)], rts.last!)) }
        for t in model.data.trails.prefix(6) {
            let c0 = t.coords.first!, p0 = proxy.convert(c0, to: .local)
            log(String(format: "  way %lld %@ first vertex %.6f,%.6f -> %@", t.id, t.name, c0.latitude, c0.longitude, p0.map { "\(Int($0.x)),\(Int($0.y))" } ?? "nil"))
        }
    }

    func syntheticClick(window w: NSWindow, localPoint p: CGPoint) {
        // SwiftUI local (top-left origin) -> window base coords (bottom-left origin).
        let h = w.contentView!.bounds.height
        sendSyntheticClick(window: w, windowPoint: CGPoint(x: p.x, y: h - p.y))
    }

    func drapeCheck(pngPath: String, window w: NSWindow) {
        guard let proxy = model.proxy else { log("drapeCheck: no proxy"); return }
        drapeAnalysis(pngPath: pngPath, window: w, trails: model.data.trails, bounds: model.mapBounds) { proxy.convert($0, to: .local) }
    }
}

@main
struct SpikeApp: App {
    init() { log("main start; pid \(getpid()); style \(Config.styleMode) elevation \(Config.elevationMode) delay \(Config.delay)s") }
    var body: some Scene {
        WindowGroup("Heavenly MapKit Spike") { ContentView() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1400, height: 900)
    }
}
