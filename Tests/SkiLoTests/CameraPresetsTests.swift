import Foundation
import Testing
@testable import SkiLo

@Suite("CameraPresets")
struct CameraPresetsTests {
    static func trail(_ id: String, _ b: GeoBounds) -> TrailGeometry {
        TrailGeometry(id: id, name: id,
                      polylines: [[GeoCoordinate(lat: b.minLat, lon: b.minLon), GeoCoordinate(lat: b.maxLat, lon: b.maxLon)]],
                      midpoint: b.center, bounds: b)
    }
    static let small = GeoBounds(minLat: 38.930, minLon: -119.938, maxLat: 38.931, maxLon: -119.937)   // ~140 m diagonal
    static let medium = GeoBounds(minLat: 38.925, minLon: -119.935, maxLat: 38.930, maxLon: -119.925)  // ~1 km diagonal
    static let large = GeoBounds(minLat: 38.915, minLon: -119.940, maxLat: 38.935, maxLon: -119.900)   // ~4 km diagonal
    let scene = MapScene(trails: [trail("t-small", small), trail("t-medium", medium), trail("t-large", large)],
                         connectors: [], lifts: [], boundary: [],
                         bounds: GeoBounds(minLat: 38.914, minLon: -119.943, maxLat: 38.966, maxLon: -119.881))
    let wide = CGSize(width: 1280, height: 800)

    @Test func presetValues() {
        let o = CameraPresets.state(for: .overview, scene: scene, viewSize: wide, current: nil)
        #expect(o.center == GeoCoordinate(lat: 38.938, lon: -119.913))
        #expect(o.distanceM == 11_000 && o.headingDeg == 180 && o.pitchDeg == 35)
        let ca = CameraPresets.state(for: .california, scene: scene, viewSize: wide, current: nil)
        #expect(ca.center == GeoCoordinate(lat: 38.932, lon: -119.938))
        #expect(ca.distanceM == 2_900 && ca.headingDeg == 120 && ca.pitchDeg == 60)
        let nv = CameraPresets.state(for: .nevada, scene: scene, viewSize: wide, current: nil)
        #expect(nv.center == GeoCoordinate(lat: 38.943, lon: -119.895))
        #expect(nv.distanceM == 2_900 && nv.headingDeg == 210 && nv.pitchDeg == 60)
        let mk = CameraPresets.state(for: .mottKillebrew, scene: scene, viewSize: wide, current: nil)
        #expect(mk.center == GeoCoordinate(lat: 38.929, lon: -119.891))
        #expect(mk.distanceM == 2_600 && mk.headingDeg == 165 && mk.pitchDeg == 60)
    }

    @Test func overviewScalesWithNarrowViews() {
        let narrow = CameraPresets.state(for: .overview, scene: scene, viewSize: CGSize(width: 600, height: 800), current: nil)
        #expect(abs(narrow.distanceM - 11_000 * 1.5) < 1e-6)
        let exact = CameraPresets.state(for: .overview, scene: scene, viewSize: CGSize(width: 900, height: 800), current: nil)
        #expect(exact.distanceM == 11_000)
        let zero = CameraPresets.state(for: .overview, scene: scene, viewSize: .zero, current: nil)
        #expect(zero.distanceM == 11_000)
    }

    @Test func fitClampsToMinimumDistance() {
        let s = CameraPresets.state(for: .fit("t-small"), scene: scene, viewSize: wide, current: nil)
        #expect(Self.small.diagonalM * 2.5 < 1_200)
        #expect(s.distanceM == 1_200)
        #expect(abs(s.center.lat - Self.small.center.lat) < 1e-12 && abs(s.center.lon - Self.small.center.lon) < 1e-12)
    }

    @Test func fitPitchRule() {
        let m = CameraPresets.state(for: .fit("t-medium"), scene: scene, viewSize: wide, current: nil)
        #expect(abs(m.distanceM - Self.medium.diagonalM * 2.5) < 1e-6)
        #expect(m.distanceM <= 3_000 && m.pitchDeg == 60)
        let l = CameraPresets.state(for: .fit("t-large"), scene: scene, viewSize: wide, current: nil)
        #expect(l.distanceM > 3_000 && l.pitchDeg == 35)
    }

    @Test func fitKeepsCurrentHeadingElse180() {
        let cur = CameraState(center: GeoCoordinate(lat: 38.9, lon: -119.9), distanceM: 5_000, headingDeg: 222, pitchDeg: 35)
        #expect(CameraPresets.state(for: .fit("t-medium"), scene: scene, viewSize: wide, current: cur).headingDeg == 222)
        #expect(CameraPresets.state(for: .fit("t-medium"), scene: scene, viewSize: wide, current: nil).headingDeg == 180)
    }

    @Test func fitUnknownTrailFallsBack() {
        let cur = CameraState(center: GeoCoordinate(lat: 38.9, lon: -119.9), distanceM: 5_000, headingDeg: 222, pitchDeg: 35)
        #expect(CameraPresets.state(for: .fit("t-nope"), scene: scene, viewSize: wide, current: cur) == cur)
        #expect(CameraPresets.state(for: .fit("t-nope"), scene: scene, viewSize: wide, current: nil).distanceM == 11_000)
    }

    @Test func sceneBuilderCoversCatalog() throws {
        let catalog = try Fixtures.bundledCatalog()
        let s = MapSceneBuilder.scene(from: catalog)
        #expect(s.trails.count == catalog.trails.count)
        #expect(s.lifts.count == catalog.lifts.count)
        #expect(s.connectors.count == catalog.connectors.filter { $0.polyline.count >= 2 }.count)
        #expect(s.bounds == catalog.bounds)
        for (g, t) in zip(s.trails, catalog.trails) {
            #expect(g.id == t.id && g.midpoint == t.midpoint && g.bounds == t.bounds)
            #expect(g.polylines.allSatisfy { $0.count >= 2 })
        }
    }
}
