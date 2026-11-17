// HeavenlyTracker MapKit spike — shared code (config, logging, OSM data model, screen-space picking).
// Compiled into both spike (SwiftUI Map) and spike_mk (MKMapView via NSViewRepresentable).

import SwiftUI
import MapKit
import AppKit

// MARK: - Config (env-driven so the orchestrator can rerun with a longer delay)

enum Config {
    static let launch = Date()
    static let jsonPath = "/Users/calebsuh/Projects/HeavenlyTracker/data/raw/heavenly_osm.json"
    static let outDir: String = ProcessInfo.processInfo.environment["SPIKE_OUT"]
        ?? "/Users/calebsuh/Projects/HeavenlyTracker/spikes/mapkit/out"
    static let delay: Double = Double(ProcessInfo.processInfo.environment["SPIKE_DELAY"] ?? "12") ?? 12
    static let elevationMode: String = ProcessInfo.processInfo.environment["SPIKE_ELEVATION"] ?? "realistic"
    static let styleMode: String = ProcessInfo.processInfo.environment["SPIKE_STYLE"] ?? "hybrid" // hybrid|imagery|standard
    static let stayOpen: Bool = ProcessInfo.processInfo.environment["SPIKE_STAY"] == "1"
    static let nativeSelection: Bool = ProcessInfo.processInfo.environment["SPIKE_NATIVE_SEL"] == "1"
    static let pitch: Double = Double(ProcessInfo.processInfo.environment["SPIKE_PITCH"] ?? "60") ?? 60
    static let heading: Double = Double(ProcessInfo.processInfo.environment["SPIKE_HEADING"] ?? "180") ?? 180
    static let distance: Double = Double(ProcessInfo.processInfo.environment["SPIKE_DISTANCE"] ?? "11000") ?? 11000
}

func log(_ s: String) {
    let t = String(format: "%7.2fs", Date().timeIntervalSince(Config.launch))
    print("[\(t)] \(s)")
    fflush(stdout)
}

// MARK: - OSM data model

struct OSMLatLon: Decodable { let lat: Double; let lon: Double }
struct OSMElement: Decodable {
    let type: String
    let id: Int64
    let tags: [String: String]?
    let geometry: [OSMLatLon]?
}
struct OSMResponse: Decodable { let elements: [OSMElement] }

enum Difficulty: String, CaseIterable {
    case easy, intermediate, advanced, expert, unknown
    var color: Color {
        switch self {
        case .easy:         return Color(red: 0.05, green: 0.80, blue: 0.25)
        case .intermediate: return Color(red: 0.15, green: 0.50, blue: 1.00)
        case .advanced:     return Color.black
        case .expert:       return Color.black          // drawn dashed = "double black"
        case .unknown:      return Color.orange
        }
    }
    var isDouble: Bool { self == .expert }
}

struct Trail: Identifiable {
    let id: Int64
    let name: String
    let difficulty: Difficulty
    let gladed: Bool
    let coords: [CLLocationCoordinate2D]
}

struct Lift: Identifiable {
    let id: Int64
    let name: String
    let kind: String
    let coords: [CLLocationCoordinate2D]
    var isMajor: Bool { kind == "gondola" || kind == "cable_car" }
}

struct ResortData {
    var trails: [Trail] = []
    var lifts: [Lift] = []
    var center = CLLocationCoordinate2D(latitude: 38.9397, longitude: -119.912)

    static func load(path: String) throws -> ResortData {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let resp = try JSONDecoder().decode(OSMResponse.self, from: data)
        var out = ResortData()
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for e in resp.elements where e.type == "way" {
            guard let tags = e.tags, let geom = e.geometry, geom.count >= 2 else { continue }
            let coords = geom.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            if tags["piste:type"] == "downhill" {
                let d = Difficulty(rawValue: tags["piste:difficulty"] ?? "") ?? .unknown
                out.trails.append(Trail(id: e.id, name: tags["name"] ?? "(unnamed \(e.id))",
                                        difficulty: d, gladed: tags["gladed"] == "yes", coords: coords))
                for c in coords {
                    minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
                    minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
                }
            } else if let kind = tags["aerialway"], kind != "station" {
                out.lifts.append(Lift(id: e.id, name: tags["name"] ?? "(unnamed lift)", kind: kind, coords: coords))
            }
        }
        if out.trails.count > 0 {
            out.center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        }
        return out
    }
}

// MARK: - Picking (pure function, screen-space nearest segment)

struct PickResult { let trail: Trail; let distancePts: CGFloat; let segmentIndex: Int }

/// Distance from p to segment ab, in the same (screen) units.
func pointSegmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let abx = b.x - a.x, aby = b.y - a.y
    let len2 = abx * abx + aby * aby
    var t: CGFloat = 0
    if len2 > 0 { t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2)) }
    let cx = a.x + t * abx, cy = a.y + t * aby
    return hypot(p.x - cx, p.y - cy)
}

/// Projects every trail vertex to screen space through `project` and returns the nearest trail
/// segment to `point` within `threshold` points. Works for any camera pitch/heading because it
/// compares in screen space, not in geographic space.
func pickTrail(at point: CGPoint, trails: [Trail], bounds: CGRect, threshold: CGFloat,
               project: (CLLocationCoordinate2D) -> CGPoint?) -> PickResult? {
    var best: PickResult? = nil
    for t in trails {
        var prev: CGPoint? = nil
        for (i, c) in t.coords.enumerated() {
            let cur = project(c)
            if let a = prev, let b = cur {
                // Skip segments that are entirely far outside the viewport (cheap reject)
                let pad: CGFloat = 50
                let big = bounds.insetBy(dx: -pad, dy: -pad)
                if big.contains(a) || big.contains(b) {
                    let d = pointSegmentDistance(point, a, b)
                    if d <= threshold, best == nil || d < best!.distancePts {
                        best = PickResult(trail: t, distancePts: d, segmentIndex: i - 1)
                    }
                }
            }
            prev = cur
        }
    }
    return best
}


// MARK: - Shared test helpers (screenshot, synthetic click, drape analysis)

/// Samples the screenshot at projected trail-vertex positions: if the projected points land
/// on trail-colored pixels, proxy.convert agrees with where MapKit actually rendered the
/// (possibly terrain-draped) polyline, which is what matters for picking.
@MainActor
func drapeAnalysis(pngPath: String, window w: NSWindow, trails: [Trail], bounds: CGRect, project: (CLLocationCoordinate2D) -> CGPoint?) {
    guard let img = NSImage(contentsOfFile: pngPath),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { log("drapeCheck: no image"); return }
    let W = cg.width, H = cg.height
    let scaleX = CGFloat(W) / w.frame.width, scaleY = CGFloat(H) / w.frame.height
    log("drapeCheck: png \(W)x\(H), window \(w.frame.size), scale \(scaleX)x\(scaleY)")
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
    guard let buf = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return }
    func px(_ x: Int, _ y: Int) -> (Int, Int, Int) { // y top-down
        let yy = H - 1 - y; let i = (yy * W + x) * 4; return (Int(buf[i]), Int(buf[i+1]), Int(buf[i+2]))
    }
    func isTrailColor(_ c: (Int, Int, Int)) -> Bool {
        let (r, g, b) = c
        let white = r > 225 && g > 225 && b > 225
        let green = g > 150 && r < 110 && b < 120
        let blue = b > 190 && r < 120 && g < 170
        let black = r < 40 && g < 40 && b < 40
        let yellow = r > 200 && g > 180 && b < 90
        return white || green || blue || black || yellow
    }
    var hits = 0, tested = 0
    var misses: [String] = []
    var offsetsPt: [CGFloat] = []      // distance (pt) from projected vertex to nearest trail-colored pixel
    var sumDx: CGFloat = 0, sumDy: CGFloat = 0, found = 0
    let maxR = Int(40 * scaleX)         // search up to 40 pt away
    for t in trails {
        let c = t.coords[t.coords.count / 2]
        guard let p = project(c), bounds.insetBy(dx: 10, dy: 10).contains(p),
              !(p.x < 470 && p.y < 150) else { continue } // skip HUD area
        tested += 1
        let cx = Int(p.x * scaleX), cy = Int(p.y * scaleY)
        // Spiral-ish search: grow radius until a trail-colored pixel is found
        var nearest: (Int, Int)? = nil
        search: for r in 0...maxR {
            for dx in -r...r { for dy in [-r, r] {
                let x = cx + dx, y = cy + dy
                if x >= 0, y >= 0, x < W, y < H, isTrailColor(px(x, y)) { nearest = (dx, dy); break search }
            } }
            if r > 0 { for dy in (-r+1)...(r-1) { for dx in [-r, r] {
                let x = cx + dx, y = cy + dy
                if x >= 0, y >= 0, x < W, y < H, isTrailColor(px(x, y)) { nearest = (dx, dy); break search }
            } } }
        }
        if let (dx, dy) = nearest {
            let dPt = hypot(CGFloat(dx), CGFloat(dy)) / scaleX
            offsetsPt.append(dPt); found += 1
            sumDx += CGFloat(dx) / scaleX; sumDy += CGFloat(dy) / scaleY
            if dPt <= 3 { hits += 1 } else if misses.count < 6 { misses.append("\(t.name) off by \(Int(dPt))pt (\(dx / Int(scaleX)),\(dy / Int(scaleY)))") }
        } else if misses.count < 6 { misses.append("\(t.name)@\(cx),\(cy): nothing within 40pt") }
    }
    let sorted = offsetsPt.sorted()
    func pct(_ q: Double) -> String { sorted.isEmpty ? "-" : String(format: "%.1f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]) }
    log("DRAPE/PROJECTION CHECK: \(hits)/\(tested) mid-vertices within 3pt of a trail-colored pixel; \(found)/\(tested) within 40pt; offset pt median \(pct(0.5)) p75 \(pct(0.75)) p90 \(pct(0.9)) max \(pct(1.0)); mean vector (\(found > 0 ? String(format: "%.1f, %.1f", sumDx / CGFloat(found), sumDy / CGFloat(found)) : "-")) pt (+y = down screen); sample misses: \(misses)")
}

func captureWindow(_ w: NSWindow, to path: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", path]
    do { try p.run(); p.waitUntilExit(); log("screencapture exit \(p.terminationStatus)") } catch { log("screencapture failed: \(error)") }
}

/// Delivers a left mouse down/up pair through NSWindow.sendEvent (in-process, no Accessibility permission).
func sendSyntheticClick(window w: NSWindow, windowPoint loc: CGPoint) {
    let ts = ProcessInfo.processInfo.systemUptime
    guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: loc, modifierFlags: [], timestamp: ts,
                                        windowNumber: w.windowNumber, context: nil, eventNumber: 9001, clickCount: 1, pressure: 1),
          let up = NSEvent.mouseEvent(with: .leftMouseUp, location: loc, modifierFlags: [], timestamp: ts + 0.05,
                                      windowNumber: w.windowNumber, context: nil, eventNumber: 9002, clickCount: 1, pressure: 0)
    else { log("could not build NSEvents"); return }
    log("synthetic click at window point \(loc)")
    w.sendEvent(down)
    w.sendEvent(up)
}

/// CPU seconds and peak RSS of this process (for the performance notes).
func logResourceUsage() {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    let user = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
    let sys = Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    log(String(format: "resource usage: cpu user %.2fs sys %.2fs, max RSS %.0f MB", user, sys, Double(ru.ru_maxrss) / 1_048_576))
}
