import Foundation

/// Per-resort facts the catalog doesn't carry: lodges, forecast point, camera views, hours.
struct ResortInfo: Identifiable, Sendable {
    struct Base: Hashable, Sendable {
        var name: String
        /// The lift whose bottom station is at this lodge.
        var liftName: String
    }
    struct View: Sendable {
        var title: String
        var short: String
        var camera: CameraState
    }

    let id: String
    let name: String
    let shortName: String
    /// Mid-mountain point used for the forecast (elevation in metres).
    let weatherPoint: GeoCoordinate
    let bases: [Base]
    let views: [View]
    let overview: CameraState
    let liftsOpenHour: Int
    let liftsCloseHour: Int
    let timeZone: String

    static let heavenly = ResortInfo(
        id: "heavenly", name: "Heavenly Mountain Resort", shortName: "Heavenly",
        weatherPoint: GeoCoordinate(lat: 38.935, lon: -119.915, ele: 2_900),
        bases: [
            Base(name: "Heavenly Village", liftName: "Heavenly Gondola"),
            Base(name: "California Lodge", liftName: "Aerial Tramway"),
            Base(name: "Stagecoach Lodge", liftName: "Stagecoach Express"),
            Base(name: "Boulder Lodge", liftName: "Boulder"),
        ],
        views: [
            View(title: "California", short: "CA", camera: CameraPresets.california),
            View(title: "Nevada", short: "NV", camera: CameraPresets.nevada),
            View(title: "Mott & Killebrew", short: "Mott/Killebrew", camera: CameraPresets.mottKillebrew),
        ],
        overview: CameraPresets.overview,
        liftsOpenHour: 9, liftsCloseHour: 16, timeZone: "America/Los_Angeles")

    static let all: [ResortInfo] = [.heavenly]
    static func info(for id: String) -> ResortInfo { all.first { $0.id == id } ?? .heavenly }
}
