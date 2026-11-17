import Foundation
import AppKit

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
