import Foundation

struct OSMWay {
    let id: Int
    let tags: [String: String]
    let coords: [(lat: Double, lon: Double)]
    var name: String { tags["name"] ?? "(unnamed)" }
    var isPiste: Bool { tags["piste:type"] == "downhill" }
    var isLift: Bool {
        guard let a = tags["aerialway"] else { return false }
        return ["chair_lift", "gondola", "cable_car", "magic_carpet", "rope_tow", "mixed_lift", "platter", "t-bar"].contains(a)
    }
}

func loadOSMWays(url: URL) throws -> [OSMWay] {
    let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    guard let elements = obj?["elements"] as? [[String: Any]] else { throw NSError(domain: "OSM", code: 1) }
    var ways: [OSMWay] = []
    for e in elements where (e["type"] as? String) == "way" {
        let id = e["id"] as? Int ?? 0
        let tags = e["tags"] as? [String: String] ?? [:]
        let geom = (e["geometry"] as? [[String: Any]] ?? []).compactMap { g -> (lat: Double, lon: Double)? in
            guard let la = g["lat"] as? Double, let lo = g["lon"] as? Double else { return nil }
            return (la, lo)
        }
        ways.append(OSMWay(id: id, tags: tags, coords: geom))
    }
    return ways
}
