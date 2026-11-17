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

    static let kirkwood = ResortInfo(
        id: "kirkwood", name: "Kirkwood Mountain Resort", shortName: "Kirkwood",
        weatherPoint: GeoCoordinate(lat: 38.677, lon: -120.066, ele: 2_600),
        bases: [
            Base(name: "Mountain Village", liftName: "Cornice Express"),
            Base(name: "Timber Creek", liftName: "TC Express"),
            Base(name: "Solitude Lodge", liftName: "Solitude"),
        ],
        views: [
            View(title: "The Wall & Cornice", short: "Wall/Cornice", camera: CameraState(center: GeoCoordinate(lat: 38.676, lon: -120.072), distanceM: 2_800, headingDeg: 200, pitchDeg: 60)),
            View(title: "Sunrise & Caples Crest", short: "Sunrise/Caples", camera: CameraState(center: GeoCoordinate(lat: 38.668, lon: -120.055), distanceM: 2_800, headingDeg: 150, pitchDeg: 60)),
        ],
        overview: CameraState(center: GeoCoordinate(lat: 38.672, lon: -120.066), distanceM: 9_500, headingDeg: 185, pitchDeg: 40),
        liftsOpenHour: 9, liftsCloseHour: 16, timeZone: "America/Los_Angeles")

    static let mtRose = ResortInfo(
        id: "mtrose", name: "Mt. Rose Ski Tahoe", shortName: "Mt. Rose",
        weatherPoint: GeoCoordinate(lat: 39.322, lon: -119.886, ele: 2_650),
        bases: [
            Base(name: "Main Lodge", liftName: "Lakeview Express"),
        ],
        views: [
            View(title: "The Chutes", short: "Chutes", camera: CameraState(center: GeoCoordinate(lat: 39.331, lon: -119.888), distanceM: 2_800, headingDeg: 200, pitchDeg: 60)),
            View(title: "Lakeview & Zephyr", short: "Lakeview/Zephyr", camera: CameraState(center: GeoCoordinate(lat: 39.316, lon: -119.886), distanceM: 2_800, headingDeg: 230, pitchDeg: 60)),
        ],
        overview: CameraState(center: GeoCoordinate(lat: 39.323, lon: -119.884), distanceM: 7_500, headingDeg: 210, pitchDeg: 40),
        liftsOpenHour: 9, liftsCloseHour: 16, timeZone: "America/Los_Angeles")

    static let all: [ResortInfo] = [.heavenly, .kirkwood, .mtRose]
    static func info(for id: String) -> ResortInfo { all.first { $0.id == id } ?? .heavenly }
}
