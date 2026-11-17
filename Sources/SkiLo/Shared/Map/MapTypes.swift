import Foundation

/// Camera and base-style types shared by the Mac and iPhone maps.
enum CameraPreset: Equatable { case overview, california, nevada, mottKillebrew, fit(Trail.ID) }
struct CameraState: Codable, Equatable {
    var center: GeoCoordinate
    var distanceM: Double
    var headingDeg: Double     // direction the camera looks, 0 = north
    var pitchDeg: Double       // ACTUAL pitch after the engine's clamp
}
enum MapBaseStyle: String, CaseIterable, Codable { case satellite, terrain, outline }

/// Static scene: everything that only changes when the catalog is reloaded.
struct MapScene {
    var trails: [TrailGeometry]          // 126 named trails
    var connectors: [[GeoCoordinate]]    // unnamed ways, dim, not selectable
    var lifts: [LiftGeometry]
    var boundary: [[GeoCoordinate]]
    var bounds: GeoBounds
}
struct TrailGeometry: Identifiable {
    let id: Trail.ID
    let name: String
    let polylines: [[GeoCoordinate]]     // one per OSM way
    let midpoint: GeoCoordinate
    let bounds: GeoBounds
}
struct LiftGeometry: Identifiable {
    let id: Lift.ID
    let name: String
    let kind: LiftKind
    let polyline: [GeoCoordinate]        // bottom → top
}

/// Per-trail dynamic style, computed by TrailStyleBuilder (UX §2.2); the engine only draws it.
struct TrailStyle: Equatable {
    enum Badge: Equatable { case none, done, bucket }
    enum Emphasis: Equatable { case normal, dimmed, hovered, selected }
    var color: RGBA            // ramp(rating), already desaturated for done
    var casing: RGBA
    var opacity: Double
    var baseWidth: Double      // pt at the 11 km overview; engine scales ×clamp(11000/distance, 1, 2)
    var dash: [Double]?        // nil = solid
    var badge: Badge
    var emphasis: Emphasis
    var label: String?         // shown only when selected
}
