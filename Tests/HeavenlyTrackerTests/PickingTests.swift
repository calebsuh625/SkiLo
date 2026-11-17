import Foundation
import Testing
@testable import HeavenlyTracker

@Suite("Picking")
struct PickingTests {
    let view = CGRect(x: 0, y: 0, width: 1000, height: 700)

    @Test func distanceToSegmentEndpoint() {
        // Beyond b along the segment's direction: the nearest point is the endpoint b.
        let d = Picking.distance(from: CGPoint(x: 13, y: 4), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0))
        #expect(abs(d - 5) < 1e-9)
        let d2 = Picking.distance(from: CGPoint(x: -3, y: -4), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0))
        #expect(abs(d2 - 5) < 1e-9)
    }

    @Test func distanceToSegmentInterior() {
        let d = Picking.distance(from: CGPoint(x: 5, y: 7), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0))
        #expect(abs(d - 7) < 1e-9)
        // Diagonal segment: distance from (0,10) to y = x is 10/√2.
        let d2 = Picking.distance(from: CGPoint(x: 0, y: 10), toSegment: CGPoint(x: -20, y: -20), CGPoint(x: 20, y: 20))
        #expect(abs(d2 - 10 / 2.0.squareRoot()) < 1e-9)
    }

    @Test func distanceToDegenerateSegment() {
        let d = Picking.distance(from: CGPoint(x: 3, y: 4), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0))
        #expect(abs(d - 5) < 1e-9)
    }

    @Test func nearestPicksCloserOfTwoParallelLines() {
        let a = ProjectedPolyline(trailID: "t-a", points: [CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 100)])
        let b = ProjectedPolyline(trailID: "t-b", points: [CGPoint(x: 100, y: 110), CGPoint(x: 400, y: 110)])
        let r1 = Picking.nearest(to: CGPoint(x: 250, y: 103), in: [a, b], bounds: view, threshold: 14)
        #expect(r1?.id == "t-a")
        #expect(abs((r1?.distance ?? 99) - 3) < 1e-9)
        let r2 = Picking.nearest(to: CGPoint(x: 250, y: 108), in: [a, b], bounds: view, threshold: 14)
        #expect(r2?.id == "t-b")
        // Order of input must not matter.
        #expect(Picking.nearest(to: CGPoint(x: 250, y: 103), in: [b, a], bounds: view, threshold: 14)?.id == "t-a")
    }

    @Test func thresholdExcludes() {
        let a = ProjectedPolyline(trailID: "t-a", points: [CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 100)])
        #expect(Picking.nearest(to: CGPoint(x: 250, y: 115), in: [a], bounds: view, threshold: 14) == nil)
        #expect(Picking.nearest(to: CGPoint(x: 250, y: 114), in: [a], bounds: view, threshold: 14)?.id == "t-a")
        #expect(Picking.nearest(to: CGPoint(x: 250, y: 114), in: [], bounds: view, threshold: 14) == nil)
    }

    @Test func nilPointsBreakSegments() {
        // The gap between (100,100) and (400,100) has no segment because the middle point is nil.
        let a = ProjectedPolyline(trailID: "t-a", points: [CGPoint(x: 100, y: 100), nil, CGPoint(x: 400, y: 100)])
        #expect(Picking.nearest(to: CGPoint(x: 250, y: 100), in: [a], bounds: view, threshold: 14) == nil)
        let b = ProjectedPolyline(trailID: "t-b", points: [CGPoint(x: 100, y: 100), nil, CGPoint(x: 400, y: 100), CGPoint(x: 500, y: 100)])
        #expect(Picking.nearest(to: CGPoint(x: 450, y: 105), in: [b], bounds: view, threshold: 14)?.id == "t-b")
    }

    @Test func boundsRejectSkipsFarOffscreenSegments() {
        // Both ends far outside the 50 pt padded viewport: rejected even though the click is on it.
        let off = ProjectedPolyline(trailID: "t-off", points: [CGPoint(x: -500, y: 100), CGPoint(x: -100, y: 100)])
        #expect(Picking.nearest(to: CGPoint(x: -300, y: 100), in: [off], bounds: view, threshold: 14) == nil)
        // One end inside the padding (x = -40 is within 50 pt): kept; click 10 pt beyond that end.
        let edge = ProjectedPolyline(trailID: "t-edge", points: [CGPoint(x: -500, y: 100), CGPoint(x: -40, y: 100)])
        #expect(Picking.nearest(to: CGPoint(x: -30, y: 100), in: [edge], bounds: view, threshold: 14)?.id == "t-edge")
    }

    @Test func onePerTrailAcrossWays() {
        // Two ways of the same trail plus one other trail: the trail's best way wins.
        let w1 = ProjectedPolyline(trailID: "t-a", points: [CGPoint(x: 0, y: 200), CGPoint(x: 300, y: 200)])
        let w2 = ProjectedPolyline(trailID: "t-a", points: [CGPoint(x: 0, y: 205), CGPoint(x: 300, y: 205)])
        let o = ProjectedPolyline(trailID: "t-b", points: [CGPoint(x: 0, y: 210), CGPoint(x: 300, y: 210)])
        let r = Picking.nearest(to: CGPoint(x: 150, y: 206), in: [w1, o, w2], bounds: view, threshold: 14)
        #expect(r?.id == "t-a")
        #expect(abs((r?.distance ?? 99) - 1) < 1e-9)
    }
}
