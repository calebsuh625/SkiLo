import Foundation
import AppKit

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

enum CameraPreset: Equatable { case overview, california, nevada, mottKillebrew, fit(Trail.ID) }
struct CameraState: Codable, Equatable {
    var center: GeoCoordinate
    var distanceM: Double
    var headingDeg: Double     // direction the camera looks, 0 = north
    var pitchDeg: Double       // ACTUAL pitch after the engine's clamp
}
enum MapBaseStyle: String, CaseIterable, Codable { case satellite, terrain, outline }

struct MapEngineCapabilities: OptionSet {
    let rawValue: Int
    static let terrain3D    = Self(rawValue: 1 << 0)
    static let pitch        = Self(rawValue: 1 << 1)
    static let hover        = Self(rawValue: 1 << 2)
    static let badges       = Self(rawValue: 1 << 3)   // engine draws midpoint glyphs itself
    static let animateStyle = Self(rawValue: 1 << 4)
    static let labels       = Self(rawValue: 1 << 5)   // engine draws the selected trail's label
    static let offline      = Self(rawValue: 1 << 6)
}

@MainActor
protocol MapEngineDelegate: AnyObject {
    func mapEngine(_ engine: any MapEngine, didSelect trailID: Trail.ID?)              // nil = clicked empty terrain
    func mapEngine(_ engine: any MapEngine, didHover trailID: Trail.ID?, at point: CGPoint?)  // point in the engine view's coords (top-left origin)
    func mapEngine(_ engine: any MapEngine, cameraDidChange camera: CameraState)
    func mapEngine(_ engine: any MapEngine, didFinishLoading ok: Bool, error: Error?)
}

@MainActor
protocol MapEngine: AnyObject {
    static var displayName: String { get }
    var capabilities: MapEngineCapabilities { get }
    var supportedBaseStyles: [MapBaseStyle] { get }
    var delegate: (any MapEngineDelegate)? { get set }

    /// The NSView to host; called once by MapHostView.
    func makeView() -> NSView

    // Inputs
    func load(scene: MapScene)                                   // (re)build all geometry
    func apply(styles: [Trail.ID: TrailStyle])                   // full map every time; engine diffs against last applied
    func setSelection(_ id: Trail.ID?)                           // visual only; truth lives in AppStore
    func setBaseStyle(_ style: MapBaseStyle)
    func setCamera(_ preset: CameraPreset, animated: Bool)
    func setCamera(_ state: CameraState, animated: Bool)
    func animateStatusChange(_ id: Trail.ID, to badge: TrailStyle.Badge)   // no-op without .animateStyle

    // Queries for SwiftUI overlays (synchronous)
    func currentCamera() -> CameraState
    func project(_ c: GeoCoordinate) -> CGPoint?                 // nil only when off-screen (MapKit cannot see terrain occlusion)
    func hitTest(_ point: CGPoint) -> Trail.ID?                  // same math the click path uses; for tests and dev hooks
}
