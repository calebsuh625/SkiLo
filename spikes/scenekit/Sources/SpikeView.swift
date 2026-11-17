import SwiftUI
import SceneKit
import AppKit

final class SpikeModel: ObservableObject {
    @Published var selectedLine = "Selected: (none) - click a trail ribbon"
    @Published var log: [String] = []
    @Published var errorText: String?
    var resort: ResortScene?
    weak var coordinator: SceneKitView.Coordinator?
    let spikeDir: URL
    let config: [String: String] = ProcessInfo.processInfo.environment

    init() {
        spikeDir = URL(fileURLWithPath: config["SPIKE_DIR"] ?? "/Users/calebsuh/Projects/HeavenlyTracker/spikes/scenekit")
        let osm = URL(fileURLWithPath: config["SPIKE_OSM"] ?? spikeDir.appendingPathComponent("../../data/raw/heavenly_osm.json").standardized.path)
        let stride = Int(config["DEM_STRIDE"] ?? "") ?? 2
        let tex = config["SPIKE_TEXTURE"] ?? "hillshade_tex.png"
        let t0 = Date()
        do {
            resort = try ResortScene(spikeDir: spikeDir, osmURL: osm, stride: stride, textureFile: tex == "none" ? nil : tex)
            resort!.stats["total_scene_build_s"] = Date().timeIntervalSince(t0)
            if let r = resort {
                log.append(String(format: "scene built in %.2fs: terrain %d verts / %d tris (stride %d of %dx%d DEM), %d piste ways, %d lifts, %d draped pts",
                                  r.stats["total_scene_build_s"] as! Double, r.terrain.vertexCount, r.terrain.triangleCount, stride,
                                  r.dem.rows, r.dem.cols, r.pisteCount, r.liftCount, r.stats["draped_line_vertices"] as! Int))
            }
        } catch {
            errorText = "Failed to build scene: \(error)"
        }
    }
}

struct SceneKitView: NSViewRepresentable {
    let resort: ResortScene
    @ObservedObject var model: SpikeModel

    func makeCoordinator() -> Coordinator { Coordinator(resort: resort, model: model) }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.scene = resort.scene
        v.pointOfView = resort.cameraNode
        v.allowsCameraControl = true
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.target = SCNVector3(CGFloat(resort.resortCenter.x), CGFloat(resort.resortCenter.y), CGFloat(resort.resortCenter.z))
        v.antialiasingMode = .multisampling4X
        v.showsStatistics = true
        v.rendersContinuously = true
        v.preferredFramesPerSecond = 120
        v.delegate = context.coordinator
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        v.addGestureRecognizer(click)
        context.coordinator.view = v
        model.coordinator = context.coordinator
        return v
    }
    func updateNSView(_ nsView: SCNView, context: Context) {}

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let resort: ResortScene
        let model: SpikeModel
        weak var view: SCNView?
        private let lock = NSLock()
        private var frameCount = 0
        private var firstFrameTime: TimeInterval = 0
        private var lastFrameTime: TimeInterval = 0
        private var selectedNode: SCNNode?
        private var selectedOriginal: Any?

        init(resort: ResortScene, model: SpikeModel) { self.resort = resort; self.model = model }

        func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            if frameCount == 0 { firstFrameTime = time }
            frameCount += 1; lastFrameTime = time
        }
        var fpsReport: (frames: Int, seconds: Double, fps: Double) {
            lock.lock(); defer { lock.unlock() }
            let d = lastFrameTime - firstFrameTime
            return (frameCount, d, d > 0 ? Double(frameCount - 1) / d : 0)
        }

        @objc func handleClick(_ g: NSClickGestureRecognizer) {
            guard let v = view else { return }
            let p = g.location(in: v)
            let r = pick(at: p)
            DispatchQueue.main.async {
                self.model.log.append("click at (\(Int(p.x)),\(Int(p.y))) -> \(r.name ?? "nothing") [\(String(format: "%.1f", r.ms)) ms]")
                self.select(info: r.info)
            }
        }

        /// Hit-test at a point in view coordinates; returns the closest node's name and the trail (if any).
        func pick(at p: CGPoint) -> (name: String?, info: TrailInfo?, ms: Double) {
            guard let v = view else { return (nil, nil, 0) }
            let t0 = Date()
            let hits = v.hitTest(p, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue, .ignoreHiddenNodes: true])
            let ms = Date().timeIntervalSince(t0) * 1000
            let first = hits.first?.node
            return (first?.name, resort.trailInfo(forNode: first), ms)
        }

        /// Highlight the chosen trail (the "crossed off" look): yellow, restoring the previous selection.
        func select(info: TrailInfo?) {
            if let prev = selectedNode, let orig = selectedOriginal { prev.geometry?.firstMaterial?.diffuse.contents = orig }
            selectedNode = nil; selectedOriginal = nil
            guard let info, let node = resort.trailNodes[info.nodeName] else { model.selectedLine = "Selected: (none)"; return }
            selectedOriginal = node.geometry?.firstMaterial?.diffuse.contents
            node.geometry?.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 1, green: 0.85, blue: 0.1, alpha: 1)
            selectedNode = node
            model.selectedLine = "Selected: \(info.name) [\(info.difficulty)] OSM way \(info.osmID) - CROSSED OFF"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: SpikeModel
    @State private var didSchedule = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let r = model.resort {
                SceneKitView(resort: r, model: model)
            } else {
                Text(model.errorText ?? "no scene").padding()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Heavenly - SceneKit terrain spike (AWS terrarium z14 DEM + OSM pistes)").font(.headline)
                Text(model.selectedLine).font(.system(.body, design: .monospaced)).foregroundStyle(.yellow)
                ForEach(Array(model.log.suffix(8).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11, design: .monospaced))
                }
                Text("green=easy  blue=intermediate  black=advanced  red=expert  gray=lift   (drag to orbit, scroll to zoom)").font(.system(size: 11))
            }
            .padding(10)
            .background(Color.black.opacity(0.65))
            .foregroundStyle(.white)
            .cornerRadius(8)
            .padding(12)
        }
        .onAppear {
            guard !didSchedule else { return }
            didSchedule = true
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { runPickTests() }
            let delay = Double(model.config["SPIKE_DELAY"] ?? "") ?? 6.5
            if model.config["SPIKE_SCREENSHOT"] != nil || model.config["SPIKE_AUTOEXIT"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { finish() }
            }
        }
    }

    /// Programmatic verification of picking: project a known trail midpoint to the screen and hit-test there
    /// (both y conventions), then aim the camera straight at the trail and hit-test the view center.
    func runPickTests() {
        guard let r = model.resort, let c = model.coordinator, let v = c.view else { return }
        let preferred = ["Gunbarrel", "Ellie's", "Mott Canyon", "Big Dipper", "Orion's", "Ridge Run"]
        let target = preferred.compactMap { n in r.trails.values.first { $0.name == n } }.first ?? r.trails.values.sorted { $0.pointCount > $1.pointCount }.first!
        let mid = SCNVector3(CGFloat(target.midpoint.x), CGFloat(target.midpoint.y), CGFloat(target.midpoint.z))
        let sp = v.projectPoint(mid)
        let h = v.bounds.height
        var results: [String] = []
        for (label, p) in [("y-as-is", CGPoint(x: sp.x, y: sp.y)), ("y-flipped", CGPoint(x: sp.x, y: h - sp.y))] {
            let res = c.pick(at: p)
            results.append("\(label) @(\(Int(p.x)),\(Int(p.y))): \(res.name ?? "nothing") [\(String(format: "%.1f", res.ms))ms]")
        }
        let projOK = c.pick(at: CGPoint(x: sp.x, y: sp.y)).info?.nodeName == target.nodeName
        // Look-at test: move the camera 600 m above / 900 m north of the trail midpoint, let a frame render,
        // then hit-test the view center (hit-testing uses the last rendered camera state).
        let saved = r.cameraNode.transform
        r.cameraNode.position = SCNVector3(mid.x, mid.y + 600, mid.z - 900)
        r.cameraNode.look(at: mid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let center = CGPoint(x: v.bounds.midX, y: v.bounds.midY)
            let res = c.pick(at: center)
            results.append("look-at center (after frame): \(res.name ?? "nothing") [\(String(format: "%.1f", res.ms))ms]")
            if model.config["SPIKE_CLOSEUP"] == nil { r.cameraNode.transform = saved }
            else { r.cameraNode.position = SCNVector3(mid.x + 400, mid.y + 700, mid.z - 1400); r.cameraNode.look(at: mid) }
            let ok = res.info?.nodeName == target.nodeName
            model.log.append("PICK TEST target=\(target.nodeName) projectPoint=\(projOK ? "PASS" : "FAIL") look-at=\(ok ? "PASS" : "FAIL")")
            model.log.append(contentsOf: results)
            r.stats["pick_test"] = ["target": target.nodeName, "projectpoint_pass": projOK, "lookat_center_pass": ok, "results": results]
            c.select(info: res.info ?? target)
        }
    }

    func finish() {
        guard let r = model.resort, let c = model.coordinator, let v = c.view else { exit(1) }
        let fr = c.fpsReport
        r.stats["render"] = ["frames": fr.frames, "seconds": fr.seconds, "fps": fr.fps, "view_px": "\(Int(v.bounds.width))x\(Int(v.bounds.height))@\(v.window?.backingScaleFactor ?? 1)"]
        model.log.append(String(format: "FPS: %.1f over %.1fs (%d frames)", fr.fps, fr.seconds, fr.frames))
        if let path = model.config["SPIKE_SCREENSHOT"] {
            // 1) SceneKit's own snapshot (does not need screen-recording permission)
            let snap = v.snapshot()
            if let tiff = snap.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "_scnsnapshot.png")))
            }
            // 2) Window capture (includes SwiftUI overlay + SceneKit statistics bar)
            if let w = v.window {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-l", "\(w.windowNumber)", path]
                try? p.run(); p.waitUntilExit()
                r.stats["screencapture_exit"] = Int(p.terminationStatus)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: r.stats, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: model.spikeDir.appendingPathComponent("run_stats.json"))
            print(String(data: data, encoding: .utf8) ?? "")
        }
        for l in model.log { print("LOG:", l) }
        if model.config["SPIKE_AUTOEXIT"] != nil { exit(0) }
    }
}
