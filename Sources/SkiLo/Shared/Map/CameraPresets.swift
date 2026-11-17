import Foundation

/// DESIGN §8.6 camera presets. Pure; MapKit's pitch clamp is handled by the engine, which reports
/// the pitch it actually kept.
enum CameraPresets {
    static let overview = CameraState(center: GeoCoordinate(lat: 38.938, lon: -119.913), distanceM: 11_000, headingDeg: 180, pitchDeg: 35)
    static let california = CameraState(center: GeoCoordinate(lat: 38.932, lon: -119.938), distanceM: 2_900, headingDeg: 120, pitchDeg: 60)
    static let nevada = CameraState(center: GeoCoordinate(lat: 38.943, lon: -119.895), distanceM: 2_900, headingDeg: 210, pitchDeg: 60)
    static let mottKillebrew = CameraState(center: GeoCoordinate(lat: 38.929, lon: -119.891), distanceM: 2_600, headingDeg: 165, pitchDeg: 60)

    static let minDistanceM = 1_200.0
    static let maxDistanceM = 30_000.0
    /// MapKit keeps 60° only at roughly ≤ 3 km (DESIGN §1.4); farther fits use 35°.
    static let closePitchLimitM = 3_000.0

    /// `current` is used for `.fit` heading and as the fallback for an unknown trail id.
    static func state(for preset: CameraPreset, scene: MapScene, viewSize: CGSize, current: CameraState?) -> CameraState {
        switch preset {
        case .overview:
            var s = overview
            if viewSize.width > 0 { s.distanceM *= max(1, 900 / Double(viewSize.width)) }
            return s
        case .california: return california
        case .nevada: return nevada
        case .mottKillebrew: return mottKillebrew
        case .camera(let s): return s
        case .bounds(let b):
            let d = max(minDistanceM, b.diagonalM * 2.2)
            return CameraState(center: b.center, distanceM: d, headingDeg: current?.headingDeg ?? 180, pitchDeg: d <= closePitchLimitM ? 60 : 35)
        case .fit(let id):
            guard let t = scene.trails.first(where: { $0.id == id }) else { return current ?? overview }
            let d = max(minDistanceM, t.bounds.diagonalM * 2.5)
            return CameraState(center: t.bounds.center, distanceM: d, headingDeg: current?.headingDeg ?? 180,
                               pitchDeg: d <= closePitchLimitM ? 60 : 35)
        }
    }
}
