import Foundation

/// WGS-84 point. JSON form is a GeoJSON-ordered array: [lon, lat] or [lon, lat, ele_m].
struct GeoCoordinate: Hashable, Sendable, Codable {
    var lat: Double
    var lon: Double
    var ele: Double?

    init(lat: Double, lon: Double, ele: Double? = nil) { self.lat = lat; self.lon = lon; self.ele = ele }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let lon = try c.decode(Double.self)
        let lat = try c.decode(Double.self)
        var ele: Double? = nil
        if !c.isAtEnd { ele = try c.decodeIfPresent(Double.self) }
        self.init(lat: lat, lon: lon, ele: ele)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(lon); try c.encode(lat)
        if let ele { try c.encode(ele) }
    }

    /// Haversine distance in metres.
    func distance(to o: GeoCoordinate) -> Double {
        let r = 6_371_008.8, d = Double.pi / 180
        let dLat = (o.lat - lat) * d, dLon = (o.lon - lon) * d
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat * d) * cos(o.lat * d) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, a.squareRoot()))
    }
}

struct GeoBounds: Hashable, Sendable, Codable {
    var minLat: Double
    var minLon: Double
    var maxLat: Double
    var maxLon: Double

    var center: GeoCoordinate { GeoCoordinate(lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2) }
    var widthM: Double { (maxLon - minLon) * 111_320 * cos(center.lat * .pi / 180) }
    var heightM: Double { (maxLat - minLat) * 110_574 }
    var diagonalM: Double { (widthM * widthM + heightM * heightM).squareRoot() }

    static func containing(_ coords: [GeoCoordinate]) -> GeoBounds {
        guard let f = coords.first else { return GeoBounds(minLat: 0, minLon: 0, maxLat: 0, maxLon: 0) }
        var b = GeoBounds(minLat: f.lat, minLon: f.lon, maxLat: f.lat, maxLon: f.lon)
        for c in coords {
            b.minLat = min(b.minLat, c.lat); b.maxLat = max(b.maxLat, c.lat)
            b.minLon = min(b.minLon, c.lon); b.maxLon = max(b.maxLon, c.lon)
        }
        return b
    }
    func padded(byMetres m: Double) -> GeoBounds {
        let dLat = m / 110_574, dLon = m / (111_320 * cos(center.lat * .pi / 180))
        return GeoBounds(minLat: minLat - dLat, minLon: minLon - dLon, maxLat: maxLat + dLat, maxLon: maxLon + dLon)
    }
}
