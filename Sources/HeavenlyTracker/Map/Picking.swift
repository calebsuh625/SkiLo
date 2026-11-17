import Foundation

/// One OSM way of a trail, projected to the map view's top-left-origin coordinates.
/// A nil point (MapKit could not project it) breaks the polyline: no segment touches it.
struct ProjectedPolyline { let trailID: Trail.ID; let points: [CGPoint?] }

/// Screen-space nearest-segment picking (DESIGN §8.3). Pure port of `pointSegmentDistance` /
/// `pickTrail` from `spikes/mapkit/Shared.swift`; works for any pitch/heading because it compares
/// in screen space.
enum Picking {
    /// Viewport padding for the cheap off-screen reject.
    static let viewportPadding: CGFloat = 50
    /// DESIGN §6.10: 14 pt (convert-vs-drawn error p90 11 pt).
    static let defaultThreshold: CGFloat = 14

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        var t: CGFloat = 0
        if len2 > 0 { t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2)) }
        let cx = a.x + t * abx, cy = a.y + t * aby
        return hypot(p.x - cx, p.y - cy)
    }

    /// Nearest trail segment within `threshold` points; one result per trail id (the best way of
    /// a trail wins). Segments with both ends outside `bounds` padded by 50 pt are skipped.
    static func nearest(to p: CGPoint, in polylines: [ProjectedPolyline], bounds: CGRect, threshold: CGFloat) -> (id: Trail.ID, distance: CGFloat)? {
        let big = bounds.insetBy(dx: -viewportPadding, dy: -viewportPadding)
        var best: (id: Trail.ID, distance: CGFloat)?
        for pl in polylines {
            var prev: CGPoint?
            for cur in pl.points {
                if let a = prev, let b = cur, big.contains(a) || big.contains(b) {
                    let d = distance(from: p, toSegment: a, b)
                    if d <= threshold, best == nil || d < best!.distance { best = (pl.trailID, d) }
                }
                prev = cur
            }
        }
        return best
    }
}
