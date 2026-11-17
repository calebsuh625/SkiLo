import SwiftUI
import MapKit

/// 3D satellite map of the resort. Trails are coloured by difficulty (done = faded, bucket =
/// yellow casing); tap a trail to open it in a sheet. Uses the shared `Picking` math.
struct PhoneMapView: View {
    @Environment(AppStore.self) private var store
    @State private var position: MapCameraPosition = .camera(Self.camera(Self.phoneOverview))
    @State private var sheetTrail: SheetTrail?
    @State private var mapSize: CGSize = .zero

    struct SheetTrail: Identifiable { let id: Trail.ID }

    var body: some View {
        let styles = TrailStyleBuilder.styles(for: store)
        MapReader { proxy in
            Map(position: $position) {
                ForEach(store.catalog.lifts) { lift in
                    MapPolyline(coordinates: lift.polyline.map(\.cl))
                        .stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
                ForEach(store.catalog.trails) { t in
                    let s = styles[t.id] ?? TrailStyleBuilder.style(rating: t.rating.total, status: .notDone, name: t.name,
                                                                     context: StyleContext(isVisible: true, isSelected: false, isHovered: false, base: .satellite))
                    let width = s.baseWidth * 1.4
                    ForEach(Array(t.geometry.enumerated()), id: \.offset) { _, seg in
                        let coords = seg.map(\.cl)
                        if s.casing != .clear {
                            MapPolyline(coordinates: coords).stroke(s.casing.color.opacity(s.opacity * 0.9), lineWidth: width + 2.5)
                        }
                        MapPolyline(coordinates: coords).stroke(s.color.color.opacity(s.opacity), lineWidth: width)
                    }
                    if store.selection == t.id {
                        Annotation(t.name, coordinate: t.midpoint.cl, anchor: .bottom) {
                            Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(.white, Ramp.color(for: store.effectiveRating(t)).color)
                        }
                    } else if store.state(for: t.id).isDone {
                        Annotation("", coordinate: t.midpoint.cl) {
                            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.white, Ramp.doneGreen.color)
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
            .mapStyle(.imagery(elevation: .realistic))
            .mapControls { MapCompass(); MapPitchToggle(); MapScaleView() }
            .onTapGesture(coordinateSpace: .local) { point in pick(at: point, proxy: proxy) }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { mapSize = $0 }
        }
        .overlay(alignment: .top) { topBar }
        .sheet(item: $sheetTrail, onDismiss: { store.select(nil, showInspector: false) }) { item in
            NavigationStack { PhoneTrailDetail(trailID: item.id) }
                .presentationDetents([.height(300), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .height(300)))
        }
        .onChange(of: store.cameraRequest) { _, req in
            guard let req else { return }
            fly(to: req)
            store.cameraRequest = nil
        }
        .onAppear {
            if let req = store.cameraRequest { fly(to: req); store.cameraRequest = nil }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            EloBadge()
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
            Menu {
                Button("Overview") { fly(to: .overview) }
                Button("California side") { fly(to: .california) }
                Button("Nevada side") { fly(to: .nevada) }
                Button("Mott & Killebrew") { fly(to: .mottKillebrew) }
            } label: {
                Image(systemName: "camera.viewfinder").font(.body)
                    .padding(7).background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Camera views")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    // MARK: picking

    private func pick(at point: CGPoint, proxy: MapProxy) {
        var lines: [ProjectedPolyline] = []
        for t in store.catalog.trails {
            for seg in t.geometry {
                lines.append(ProjectedPolyline(trailID: t.id, points: seg.map { proxy.convert($0.cl, to: .local) }))
            }
        }
        let bounds = CGRect(origin: .zero, size: mapSize)
        if let hit = Picking.nearest(to: point, in: lines, bounds: bounds, threshold: 24) {
            store.select(hit.id, showInspector: false)
            sheetTrail = SheetTrail(id: hit.id)
            UISelectionFeedbackGenerator().selectionChanged()
        } else {
            store.select(nil, showInspector: false)
            sheetTrail = nil
        }
    }

    // MARK: camera

    private func fly(to preset: CameraPreset) {
        let state: CameraState
        switch preset {
        case .overview: state = Self.phoneOverview
        case .california: state = CameraPresets.california
        case .nevada: state = CameraPresets.nevada
        case .mottKillebrew: state = CameraPresets.mottKillebrew
        case .fit(let id):
            guard let t = store.trail(id) else { return }
            let far = t.geometry.joined().map { $0.distance(to: t.midpoint) }.max() ?? 500
            state = CameraState(center: t.midpoint, distanceM: min(max(far * 4.5, 1_200), 8_000), headingDeg: 180, pitchDeg: 55)
            sheetTrail = SheetTrail(id: id)
        }
        withAnimation(.easeInOut(duration: 1.0)) { position = .camera(Self.camera(state)) }
    }

    /// The Mac's overview, pulled back so the whole resort fits a portrait phone screen.
    static var phoneOverview: CameraState {
        var s = CameraPresets.overview
        s.distanceM *= 1.9
        s.pitchDeg = 45
        return s
    }

    static func camera(_ s: CameraState) -> MapCamera {
        MapCamera(centerCoordinate: s.center.cl, distance: s.distanceM, heading: s.headingDeg, pitch: s.pitchDeg)
    }
}

extension GeoCoordinate {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}
