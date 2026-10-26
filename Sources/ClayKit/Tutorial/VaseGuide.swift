import Foundation
import simd

/// The ghosted "Ceramic Vase" outline used by the first-run tutorial (and as a demo model).
/// Base Ø50 mm, height 120 mm.
public enum VaseGuide {
    /// Right-hand half profile, bottom to top (u, v) in mm.
    static let rightProfile: [Vec2] = [
        Vec2(25, 0), Vec2(31, 10), Vec2(36.5, 27), Vec2(38, 45), Vec2(34, 64),
        Vec2(24.5, 82), Vec2(15.5, 95), Vec2(14, 104), Vec2(16.5, 114), Vec2(20, 120),
    ]

    /// Closed silhouette: flat base, curved sides, flat lip.
    public static func silhouette(depthScale: Float = 1) -> SketchPath {
        let pts = rightProfile.map { Vec2($0.x * depthScale, $0.y) }
        let right = SketchPath.smoothCurve(through: pts, closed: false)
        let left = right.reversed().map { s in
            CubicBezier(Vec2(-s.p3.x, s.p3.y), Vec2(-s.p2.x, s.p2.y), Vec2(-s.p1.x, s.p1.y), Vec2(-s.p0.x, s.p0.y))
        }
        let bottomL = Vec2(-pts[0].x, 0), bottomR = pts[0]
        let topR = pts[pts.count - 1], topL = Vec2(-topR.x, topR.y)
        var segs: [CubicBezier] = [.line(bottomL, bottomR)]
        segs += right
        segs.append(.line(topR, topL))
        segs += left
        return SketchPath(segments: segs, closed: true, kind: .freehand)
    }

    public static var frontSketch: Sketch { Sketch(paths: [silhouette()]) }
    /// Slightly oval: the side (depth) profile is 86% of the front.
    public static var sideSketch: Sketch { Sketch(paths: [silhouette(depthScale: 0.86)]) }

    /// Simulated hand-drawn trace of the guide (wobbly samples), for "Show me" and tests.
    public static func handTrace(depthScale: Float = 1, wobble: Float = 0.6) -> [Vec2] {
        let pts = silhouette(depthScale: depthScale).polyline(samplesPerSegment: 20)
        return pts.enumerated().map { i, p in
            p + Vec2(sin(Float(i) * 0.9), cos(Float(i) * 1.3)) * wobble
        }
    }
}
