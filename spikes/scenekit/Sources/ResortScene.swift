import Foundation
import SceneKit
import AppKit
import simd

struct TrailInfo {
    let nodeName: String
    let osmID: Int
    let name: String
    let difficulty: String
    let midpoint: SIMD3<Float>
    let color: NSColor
    let pointCount: Int
}

func difficultyColor(_ d: String?) -> NSColor {
    switch d {
    case "easy": return NSColor(calibratedRed: 0.16, green: 0.82, blue: 0.28, alpha: 1)
    case "intermediate": return NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.98, alpha: 1)
    case "advanced": return NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.06, alpha: 1)
    case "expert": return NSColor(calibratedRed: 0.96, green: 0.18, blue: 0.14, alpha: 1)
    default: return NSColor(calibratedWhite: 0.65, alpha: 1)
    }
}

/// Builds the SceneKit scene: textured terrain mesh, draped piste ribbons, lifts, lights, camera.
final class ResortScene {
    let scene = SCNScene()
    let dem: DEM
    let terrain: TerrainGrid
    let proj: GeoProjection
    private(set) var trails: [String: TrailInfo] = [:]     // nodeName -> info
    private(set) var trailNodes: [String: SCNNode] = [:]
    private(set) var resortCenter = SIMD3<Float>(0, 0, 0)
    let cameraNode = SCNNode()
    var stats: [String: Any] = [:]
    private(set) var pisteCount = 0
    private(set) var liftCount = 0

    init(spikeDir: URL, osmURL: URL, stride: Int, textureFile: String?) throws {
        var t0 = Date()
        dem = try DEM(directory: spikeDir)
        let e = dem.meta.extent_pixel_centers
        proj = GeoProjection(lat0: (e.lat_n + e.lat_s) / 2, lon0: (e.lon_w + e.lon_e) / 2)
        stats["dem_load_s"] = Date().timeIntervalSince(t0); t0 = Date()

        terrain = TerrainGrid(dem: dem, stride: stride, proj: proj)
        let texURL = textureFile.map { spikeDir.appendingPathComponent($0) }
        let terrainNode = SCNNode(geometry: terrain.makeGeometry(textureURL: texURL))
        terrainNode.name = "terrain"
        terrainNode.categoryBitMask = 1
        scene.rootNode.addChildNode(terrainNode)
        stats["terrain_build_s"] = Date().timeIntervalSince(t0); t0 = Date()
        stats["terrain_vertices"] = terrain.vertexCount
        stats["terrain_triangles"] = terrain.triangleCount
        stats["dem_rows"] = dem.rows; stats["dem_cols"] = dem.cols; stats["stride"] = stride
        stats["texture"] = textureFile ?? "none"

        let ways = try loadOSMWays(url: osmURL)
        let trailsParent = SCNNode(); trailsParent.name = "trails"
        let liftsParent = SCNNode(); liftsParent.name = "lifts"
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var lineVerts = 0
        for w in ways where w.isPiste || w.isLift {
            let pts = drape(w.coords, offset: w.isPiste ? 4 : 12, step: 10)
            let color = w.isPiste ? difficultyColor(w.tags["piste:difficulty"]) : NSColor(calibratedWhite: 0.42, alpha: 1)
            guard let geo = ribbonGeometry(points: pts, width: w.isPiste ? 14 : 8, color: color) else { continue }
            let node = SCNNode(geometry: geo)
            let nodeName = (w.isPiste ? "piste:" : "lift:") + "\(w.id)|" + w.name
            node.name = nodeName
            node.categoryBitMask = 2
            lineVerts += pts.count
            if w.isPiste {
                trailsParent.addChildNode(node)
                trails[nodeName] = TrailInfo(nodeName: nodeName, osmID: w.id, name: w.name, difficulty: w.tags["piste:difficulty"] ?? "unknown",
                                             midpoint: pts[pts.count / 2], color: color, pointCount: pts.count)
                trailNodes[nodeName] = node
                pisteCount += 1
                for p in pts { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            } else {
                liftsParent.addChildNode(node)
                liftCount += 1
            }
        }
        scene.rootNode.addChildNode(trailsParent)
        scene.rootNode.addChildNode(liftsParent)
        stats["trails_build_s"] = Date().timeIntervalSince(t0)
        stats["piste_ways"] = pisteCount; stats["lift_ways"] = liftCount; stats["draped_line_vertices"] = lineVerts
        let c = (lo + hi) / 2
        resortCenter = SIMD3(c.x, c.y, c.z)
        stats["piste_extent_m"] = ["east_west": hi.x - lo.x, "north_south": hi.z - lo.z, "elev_min": lo.y, "elev_max": hi.y]

        // Lighting: sun from the NW at 45 deg, plus ambient fill.
        let sun = SCNNode()
        sun.light = SCNLight(); sun.light!.type = .directional
        sun.light!.intensity = 1000; sun.light!.color = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.9, alpha: 1)
        sun.position = SCNVector3(-5000, 7071, -5000)
        sun.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(sun)
        let amb = SCNNode(); amb.light = SCNLight(); amb.light!.type = .ambient; amb.light!.intensity = 400
        scene.rootNode.addChildNode(amb)

        // Camera: north-northwest of the resort (over the lake, the classic South Lake Tahoe view),
        // ~30 deg pitch, looking south at the resort center so the north-facing runs are visible.
        let cam = SCNCamera(); cam.zNear = 5; cam.zFar = 80000; cam.fieldOfView = 55
        cameraNode.camera = cam
        cameraNode.position = SCNVector3(CGFloat(resortCenter.x - 1500), CGFloat(resortCenter.y + 3600), CGFloat(resortCenter.z - 6200))
        cameraNode.look(at: SCNVector3(CGFloat(resortCenter.x), CGFloat(resortCenter.y), CGFloat(resortCenter.z)))
        scene.rootNode.addChildNode(cameraNode)
        scene.background.contents = NSColor(calibratedRed: 0.70, green: 0.82, blue: 0.95, alpha: 1)
    }

    /// Densify a lat/lon polyline every `step` meters and lift it onto the rendered terrain surface + offset.
    func drape(_ coords: [(lat: Double, lon: Double)], offset: Float, step: Double) -> [SIMD3<Float>] {
        var pts: [SIMD3<Float>] = []
        guard coords.count >= 2 else { return pts }
        func point(_ lat: Double, _ lon: Double) -> SIMD3<Float> {
            let (e, n) = proj.enu(lat: lat, lon: lon)
            return SIMD3(Float(e), terrain.surfaceHeight(lat: lat, lon: lon) + offset, Float(-n))
        }
        for k in 0..<(coords.count - 1) {
            let a = coords[k], b = coords[k + 1]
            let (ea, na) = proj.enu(lat: a.lat, lon: a.lon)
            let (eb, nb) = proj.enu(lat: b.lat, lon: b.lon)
            let n = max(Int(ceil(hypot(eb - ea, nb - na) / step)), 1)
            for s in 0..<n {
                let t = Double(s) / Double(n)
                pts.append(point(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t))
            }
        }
        let last = coords[coords.count - 1]
        pts.append(point(last.lat, last.lon))
        return pts
    }

    func trailInfo(forNode node: SCNNode?) -> TrailInfo? {
        var n = node
        while let cur = n {
            if let name = cur.name, let info = trails[name] { return info }
            n = cur.parent
        }
        return nil
    }
}
