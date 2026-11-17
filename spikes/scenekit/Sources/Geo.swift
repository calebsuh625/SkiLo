import Foundation
import simd

/// Local east-north-up projection (equirectangular about a center point; error < 0.1% over 12 km).
/// Scene axes: x = east, y = up (meters above sea level), z = south (-north), right-handed.
struct GeoProjection {
    let lat0: Double
    let lon0: Double
    static let R = 6378137.0
    func enu(lat: Double, lon: Double) -> (east: Double, north: Double) {
        let east = (lon - lon0) * .pi / 180 * Self.R * cos(lat0 * .pi / 180)
        let north = (lat - lat0) * .pi / 180 * Self.R
        return (east, north)
    }
}

struct DEMMeta: Decodable {
    struct Extent: Decodable { let lon_w, lon_e, lat_n, lat_s: Double }
    let rows: Int
    let cols: Int
    let extent_pixel_centers: Extent
    let resolution_m_at_mid_lat: Double
    let elev_min_m: Double
    let elev_max_m: Double
}

/// Heightmap on the Web-Mercator z14 pixel grid (columns uniform in lon, rows uniform in mercator-y).
final class DEM {
    let meta: DEMMeta
    let rows: Int
    let cols: Int
    let data: [Float]
    private let mercN: Double
    private let mercS: Double

    init(directory: URL) throws {
        let metaData = try Data(contentsOf: directory.appendingPathComponent("meta.json"))
        meta = try JSONDecoder().decode(DEMMeta.self, from: metaData)
        rows = meta.rows; cols = meta.cols
        let raw = try Data(contentsOf: directory.appendingPathComponent("dem.f32"))
        guard raw.count == rows * cols * 4 else {
            throw NSError(domain: "DEM", code: 1, userInfo: [NSLocalizedDescriptionKey: "dem.f32 size mismatch: \(raw.count) != \(rows*cols*4)"])
        }
        data = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        mercN = DEM.mercator(meta.extent_pixel_centers.lat_n)
        mercS = DEM.mercator(meta.extent_pixel_centers.lat_s)
    }
    static func mercator(_ latDeg: Double) -> Double { let r = latDeg * .pi / 180; return log(tan(r) + 1 / cos(r)) }
    func lat(forRow r: Double) -> Double { let y = mercN + (mercS - mercN) * r / Double(rows - 1); return atan(sinh(y)) * 180 / .pi }
    func lon(forCol c: Double) -> Double { let e = meta.extent_pixel_centers; return e.lon_w + (e.lon_e - e.lon_w) * c / Double(cols - 1) }
    func gridCoords(lat: Double, lon: Double) -> (row: Double, col: Double) {
        let e = meta.extent_pixel_centers
        let c = (lon - e.lon_w) / (e.lon_e - e.lon_w) * Double(cols - 1)
        let r = (DEM.mercator(lat) - mercN) / (mercS - mercN) * Double(rows - 1)
        return (r, c)
    }
    subscript(r: Int, c: Int) -> Float { data[min(max(r, 0), rows - 1) * cols + min(max(c, 0), cols - 1)] }
    /// Bilinear elevation from the full-resolution DEM.
    func elevation(lat: Double, lon: Double) -> Float {
        let (r, c) = gridCoords(lat: lat, lon: lon)
        let i = min(max(Int(floor(r)), 0), rows - 2), j = min(max(Int(floor(c)), 0), cols - 2)
        let fr = Float(min(max(r - Double(i), 0), 1)), fc = Float(min(max(c - Double(j), 0), 1))
        let a = self[i, j] * (1 - fc) + self[i, j + 1] * fc
        let b = self[i + 1, j] * (1 - fc) + self[i + 1, j + 1] * fc
        return a * (1 - fr) + b * fr
    }
}
