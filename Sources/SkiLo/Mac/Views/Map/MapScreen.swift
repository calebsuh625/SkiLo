import SwiftUI
import AppKit

/// Engine → store bridge plus the transient overlay state (tooltip, offline banner).
@MainActor @Observable
final class MapScreenModel: MapEngineDelegate {
    @ObservationIgnored weak var store: AppStore?
    var hoverID: Trail.ID?
    var hoverPoint: CGPoint?
    var tooltipVisible = false
    var offline = false
    var offlineDismissed = false
    // Fly-through HUD
    var flying = false
    var flyTitle = ""
    var flyLabel = ""
    var flyProgress = 0.0
    var flyPaused = false
    @ObservationIgnored private var tooltipWork: DispatchWorkItem?

    static let cameraDefaultsKey = "map.lastCamera"

    func mapEngine(_ engine: any MapEngine, didSelect trailID: Trail.ID?) {
        guard let store else { return }
        if let trailID { store.select(trailID, showInspector: true) } else { store.selection = nil }
    }

    func mapEngine(_ engine: any MapEngine, didHover trailID: Trail.ID?, at point: CGPoint?) {
        store?.hover = trailID
        hoverID = trailID
        hoverPoint = point
        tooltipVisible = false
        tooltipWork?.cancel()
        guard trailID != nil else { return }
        let w = DispatchWorkItem { [weak self] in self?.tooltipVisible = true }
        tooltipWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    func mapEngine(_ engine: any MapEngine, cameraDidChange camera: CameraState) {
        guard !DevHooks.isScripted, let data = try? JSONEncoder().encode(camera) else { return }
        UserDefaults.standard.set(data, forKey: Self.cameraDefaultsKey)
    }

    func mapEngine(_ engine: any MapEngine, didFinishLoading ok: Bool, error: Error?) {
        if !ok { offline = true }
    }

    func mapEngine(_ engine: any MapEngine, didClickAt coordinate: GeoCoordinate, trailID: Trail.ID?) -> Bool {
        guard let store, let end = store.directions.picking else { return false }
        // A clicked trail as the destination means "ski it"; anywhere else drops a pin.
        if end == .to, let trailID { store.setDirections(.to, .trail(trailID)) }
        else { store.setDirections(end, .point(coordinate)) }
        return true
    }

    static func savedCamera() -> CameraState? {
        guard !DevHooks.isScripted, let d = UserDefaults.standard.data(forKey: cameraDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(CameraState.self, from: d)
    }
}

struct MapScreen: View {
    @Environment(AppStore.self) private var store
    @State private var engine: any MapEngine = MapKitEngine()
    @State private var model = MapScreenModel()
    @State private var loaded = false

    init() {}

    private struct StyleKey: Hashable {
        var revision: Int
        var filter: TrailFilter
        var selection: Trail.ID?
        var hover: Trail.ID?
        var base: MapBaseStyle
    }
    private var styleKey: StyleKey {
        StyleKey(revision: store.revision, filter: store.filter, selection: store.selection, hover: store.hover, base: store.mapBaseStyle)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                MapHostView(engine: engine)
                MapOverlays(engine: engine, viewSize: geo.size, model: model)
                if store.directions.isOpen && !model.flying {
                    DirectionsPanel()
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if let plan = store.shownPlan, !store.directions.isOpen, !model.flying {
                    HStack(spacing: 10) {
                        Image(systemName: "map.fill").foregroundStyle(.tint)
                        Text("Day plan · \(plan.stops.count) trails · back by \(Format.time(plan.finishTime))").font(.callout.weight(.medium))
                        Button { store.flyThroughPlan() } label: { Image(systemName: "play.fill") }.buttonStyle(.borderless).help("Fly through the day")
                        Button { store.section = .today } label: { Image(systemName: "list.bullet") }.buttonStyle(.borderless).help("Open the plan")
                        Button { store.shownPlan = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Hide the plan")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 4, y: 1)
                    .padding(.bottom, 56)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                if model.flying {
                    FlyThroughHUD(model: model, onPause: { engine.setFlyThroughPaused($0) }, onStop: { engine.stopFlyThrough() })
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.directions.isOpen)
            .animation(.easeOut(duration: 0.2), value: model.flying)
        }
        .onChange(of: store.mapRoute) { _, r in engine.setRoute(r) }
        .onChange(of: store.resortID) { _, _ in
            engine.stopFlyThrough()
            engine.load(scene: MapSceneBuilder.scene(from: store.catalog))
            applyStyles()
            engine.setRoute(store.mapRoute)
            engine.setCamera(store.overviewPreset, animated: false)
            store.cameraRequest = nil
        }
        .onChange(of: store.flyRequest) { _, req in startFly(req) }
        .onChange(of: store.stopFlyRequested) { _, stop in
            if stop { engine.stopFlyThrough(); store.stopFlyRequested = false }
        }
        .onAppear(perform: setUp)
        .onChange(of: styleKey) { _, _ in applyStyles() }
        .onChange(of: store.cameraRequest) { _, req in
            guard let req else { return }
            engine.setCamera(req, animated: true)
            store.cameraRequest = nil
        }
        .onChange(of: store.lastStatusChange) { _, change in
            guard let change else { return }
            engine.animateStatusChange(change.trailID, to: change.badge)
            store.lastStatusChange = nil
        }
        .toolbar { MapToolbar(engine: engine) }
    }

    private func setUp() {
        guard !loaded else { return }
        loaded = true
        model.store = store
        engine.delegate = model
        engine.load(scene: MapSceneBuilder.scene(from: store.catalog))
        engine.setBaseStyle(store.mapBaseStyle)
        applyStyles()
        engine.setRoute(store.mapRoute)
        // Defer the camera until the view has a size (overview distance depends on the width).
        DispatchQueue.main.async {
            // A saved camera from another resort's session would open over the wrong mountain.
            let bounds = store.catalog.bounds.padded(byMetres: 3_000)
            if let saved = MapScreenModel.savedCamera(),
               (bounds.minLat...bounds.maxLat).contains(saved.center.lat), (bounds.minLon...bounds.maxLon).contains(saved.center.lon) {
                engine.setCamera(saved, animated: false)
            } else { engine.setCamera(store.overviewPreset, animated: false) }
            if let req = store.cameraRequest { engine.setCamera(req, animated: true); store.cameraRequest = nil }
            if store.flyRequest != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { startFly(store.flyRequest) } }
        }
        if DevHooks.isScripted, let target = DevHooks.env["HT_CLICK"] { SyntheticClickTest.schedule(target: target, engine: engine, store: store) }
    }

    private func startFly(_ req: FlyRequest?) {
        guard let req else { return }
        store.flyRequest = nil
        model.flyTitle = req.title
        model.flyLabel = ""
        model.flyProgress = 0
        model.flyPaused = false
        model.flying = true
        store.isFlying = true
        engine.startFlyThrough(req, progress: { p, label in
            model.flyProgress = p
            if model.flyLabel != label { model.flyLabel = label }
        }, finished: {
            model.flying = false
            store.isFlying = false
        })
    }

    private func applyStyles() {
        engine.setBaseStyle(store.mapBaseStyle)
        engine.setSelection(store.selection)
        engine.apply(styles: TrailStyleBuilder.styles(for: store))
    }
}

/// Map-section toolbar: Camera, Base style, Filter, Legend, Fit (UX §2, BUILD_PLAN WP3.6).
private struct MapToolbar: ToolbarContent {
    @Environment(AppStore.self) private var store
    let engine: any MapEngine

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Button("Overview") { store.requestCamera(.overview) }
                ForEach(Array(store.resort.views.enumerated()), id: \.offset) { _, v in
                    Button(v.title) { store.requestCamera(.camera(v.camera)) }
                }
            } label: { Label("Camera", systemImage: "camera.viewfinder") }
            .help("Camera presets")

            Menu {
                ForEach(MapBaseStyle.allCases, id: \.self) { s in
                    Button {
                        store.mapBaseStyle = s
                    } label: {
                        if store.mapBaseStyle == s { Label(baseStyleTitle(s), systemImage: "checkmark") } else { Text(baseStyleTitle(s)) }
                    }
                    .disabled(!engine.supportedBaseStyles.contains(s))
                }
            } label: { Label("Base Map", systemImage: "square.3.layers.3d") }
            .help("Base map style")

            FilterMenu()

            Button { store.legendShown.toggle() } label: {
                Label("Legend", systemImage: store.legendShown ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
            }
            .help(store.legendShown ? "Hide legend" : "Show legend")

            Button { store.directions.isOpen ? store.closeDirections() : store.openDirections() } label: {
                Label("Directions", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .help("Get from A to B (⌘G)")

            Button { if let id = store.selection { store.requestCamera(.fit(id)) } } label: {
                Label("Fit", systemImage: "scope")
            }
            .disabled(store.selection == nil)
            .help("Fit the selected trail")
        }
    }
}

private func baseStyleTitle(_ s: MapBaseStyle) -> String {
    switch s { case .satellite: "Satellite"; case .terrain: "Terrain"; case .outline: "Outline" }
}

/// `HT_CLICK=<trail id>` dev hook (scripted runs only): ~5 s after the map appears, find a projected
/// vertex of the trail that the engine's own hit test resolves to that trail, deliver a real
/// mouse down/up through `NSWindow.sendEvent`, then log PASS/FAIL from `store.selection`.
@MainActor
enum SyntheticClickTest {
    static func schedule(target: Trail.ID, engine: any MapEngine, store: AppStore) {
        let delay = Double(DevHooks.env["HT_CLICK_DELAY"] ?? "") ?? 5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { run(target: target, engine: engine, store: store) }
    }

    private static func run(target: Trail.ID, engine: any MapEngine, store: AppStore) {
        let view = engine.makeView()
        guard let window = view.window, let trail = store.trail(target) else { log("FAIL (no window or unknown trail \(target))"); return }
        let b = view.bounds
        let center = CGPoint(x: b.midX, y: b.midY)
        // Avoid the SwiftUI chrome: legend (top-left), chips (bottom-right), Apple logo (bottom-left).
        let safe = b.insetBy(dx: 40, dy: 40)
        let legend = CGRect(x: 0, y: 0, width: 260, height: 320)
        let chips = CGRect(x: b.maxX - 420, y: b.maxY - 90, width: 420, height: 90)
        var best: (CGPoint, CGFloat)?
        var visible = 0
        for c in trail.allCoordinates {
            guard let p = engine.project(c), safe.contains(p), !legend.contains(p), !chips.contains(p) else { continue }
            visible += 1
            guard engine.hitTest(p) == target else { continue }
            let d = hypot(p.x - center.x, p.y - center.y)
            if best == nil || d < best!.1 { best = (p, d) }
        }
        guard let (pt, _) = best else { log("FAIL (no unambiguous vertex of \(target); \(visible) of \(trail.allCoordinates.count) vertices on screen)"); return }
        store.selection = nil
        let local = view.isFlipped ? pt : CGPoint(x: pt.x, y: b.height - pt.y)
        let win = view.convert(local, to: nil)
        let ts = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: win, modifierFlags: [], timestamp: ts, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 9001, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: win, modifierFlags: [], timestamp: ts + 0.05, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 9002, clickCount: 1, pressure: 0)
        else { log("FAIL (could not build events)"); return }
        log(String(format: "clicking %@ (%@) at view (%.0f, %.0f) window (%.0f, %.0f)", target, trail.name, pt.x, pt.y, win.x, win.y))
        window.sendEvent(down)
        window.sendEvent(up)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let got = store.selection
            log("expected \(target) → selection \(got ?? "nil") => \(got == target ? "PASS" : "FAIL")")
        }
    }

    private static func log(_ s: String) { NSLog("HT_CLICK %@", s) }
}
