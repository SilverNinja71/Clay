import Foundation
import simd

// MARK: - Cubic Bézier segment

/// One cubic Bézier segment: p0 → p3 with control points p1, p2 (all in sketch-plane millimetres).
public struct CubicBezier: Codable, Equatable, Sendable {
    public var p0, p1, p2, p3: Vec2

    public init(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2) {
        self.p0 = p0; self.p1 = p1; self.p2 = p2; self.p3 = p3
    }

    /// A straight segment (control points at the thirds, so speed is uniform).
    public static func line(_ a: Vec2, _ b: Vec2) -> CubicBezier {
        CubicBezier(a, a + (b - a) / 3, a + (b - a) * 2 / 3, b)
    }

    @inlinable public func point(at t: Float) -> Vec2 {
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return p0 * a + p1 * b + p2 * c + p3 * d
    }

    /// First derivative.
    @inlinable public func derivative(at t: Float) -> Vec2 {
        let mt = 1 - t
        let a: Vec2 = (p1 - p0) * (3 * mt * mt)
        let b: Vec2 = (p2 - p1) * (6 * mt * t)
        let c: Vec2 = (p3 - p2) * (3 * t * t)
        return a + b + c
    }

    /// Second derivative.
    @inlinable public func secondDerivative(at t: Float) -> Vec2 {
        let a: Vec2 = p2 - p1 * 2 + p0
        let b: Vec2 = p3 - p2 * 2 + p1
        return a * (6 * (1 - t)) + b * (6 * t)
    }

    public func tangent(at t: Float) -> Vec2 {
        let d = derivative(at: t)
        if simd_length_squared(d) > 1e-12 { return simd_normalize(d) }
        return (p3 - p0).safeNormalized
    }

    /// De Casteljau split at t.
    public func split(at t: Float) -> (CubicBezier, CubicBezier) {
        let a = simd_mix(p0, p1, Vec2(repeating: t)), b = simd_mix(p1, p2, Vec2(repeating: t)), c = simd_mix(p2, p3, Vec2(repeating: t))
        let d = simd_mix(a, b, Vec2(repeating: t)), e = simd_mix(b, c, Vec2(repeating: t))
        let f = simd_mix(d, e, Vec2(repeating: t))
        return (CubicBezier(p0, a, d, f), CubicBezier(f, e, c, p3))
    }

    /// Arc length by Gauss–Legendre quadrature (5 points).
    public var length: Float {
        let xs: [Float] = [-0.9061798, -0.5384693, 0, 0.5384693, 0.9061798]
        let ws: [Float] = [0.2369269, 0.4786287, 0.5688889, 0.4786287, 0.2369269]
        var s: Float = 0
        for i in 0..<5 { s += ws[i] * simd_length(derivative(at: 0.5 * xs[i] + 0.5)) }
        return s * 0.5
    }

    /// Evenly spaced parameter samples appended to `out` (excluding the end point when `dropLast`).
    public func flatten(into out: inout [Vec2], samples: Int, dropLast: Bool) {
        let n = max(1, samples)
        for i in 0...n {
            if dropLast && i == n { break }
            out.append(point(at: Float(i) / Float(n)))
        }
    }

    public func transformed(_ f: (Vec2) -> Vec2) -> CubicBezier {
        CubicBezier(f(p0), f(p1), f(p2), f(p3))
    }

    /// Closest point on the curve to `q`: coarse sampling refined by Newton iterations.
    public func closestParameter(to q: Vec2) -> Float {
        var bestT: Float = 0, best = Float.greatestFiniteMagnitude
        for i in 0...16 {
            let t = Float(i) / 16
            let d = simd_length_squared(point(at: t) - q)
            if d < best { best = d; bestT = t }
        }
        var t = bestT
        for _ in 0..<4 {
            let p = point(at: t) - q, d1 = derivative(at: t), d2 = secondDerivative(at: t)
            let den = simd_dot(d1, d1) + simd_dot(p, d2)
            if abs(den) < 1e-9 { break }
            t = clamp(t - simd_dot(p, d1) / den, 0, 1)
        }
        return t
    }
}

// MARK: - Editable anchors

/// An anchor with handles stored relative to its position, like a vector drawing app.
public struct BezierAnchor: Codable, Equatable, Sendable {
    public var position: Vec2
    public var inHandle: Vec2
    public var outHandle: Vec2
    public init(_ position: Vec2, inHandle: Vec2 = .zero, outHandle: Vec2 = .zero) {
        self.position = position; self.inHandle = inHandle; self.outHandle = outHandle
    }
    public var isCorner: Bool {
        let a = inHandle.safeNormalized, b = outHandle.safeNormalized
        if a == .zero || b == .zero { return true }
        return simd_dot(a, b) > -0.985
    }
}

public enum SketchPlane: String, Codable, CaseIterable, Sendable {
    case front, side, top

    public var title: String {
        switch self { case .front: "Front"; case .side: "Side"; case .top: "Top" }
    }

    /// Maps a point on the sketch plane (u right, v up) to world space (Y up).
    /// Front looks down −Z (u → +X). Side is the Right view looking down −X (u → −Z).
    public func worldPoint(_ p: Vec2, offset: Float = 0) -> Vec3 {
        switch self {
        case .front: Vec3(p.x, p.y, offset)
        case .side: Vec3(offset, p.y, -p.x)
        case .top: Vec3(p.x, offset, -p.y)
        }
    }

    /// Inverse of `worldPoint` (drops the plane-normal component).
    public func planePoint(_ w: Vec3) -> Vec2 {
        switch self {
        case .front: Vec2(w.x, w.y)
        case .side: Vec2(-w.z, w.y)
        case .top: Vec2(w.x, -w.z)
        }
    }

    public var normal: Vec3 {
        switch self { case .front: Vec3(0, 0, 1); case .side: Vec3(1, 0, 0); case .top: Vec3(0, 1, 0) }
    }
}

/// A continuous sketched curve (open or closed loop).
public struct SketchPath: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case freehand, pen, polyline, circle, rectangle }

    public var id: UUID
    public var anchors: [BezierAnchor]
    public var closed: Bool
    public var kind: Kind

    public init(id: UUID = UUID(), anchors: [BezierAnchor], closed: Bool, kind: Kind = .freehand) {
        self.id = id; self.anchors = anchors; self.closed = closed; self.kind = kind
    }

    /// Builds anchors from a chain of segments (each segment's p3 must equal the next one's p0).
    public init(id: UUID = UUID(), segments: [CubicBezier], closed: Bool, kind: Kind = .freehand) {
        var anchors: [BezierAnchor] = []
        for (i, s) in segments.enumerated() {
            if i == 0 { anchors.append(BezierAnchor(s.p0)) }
            anchors[anchors.count - 1].outHandle = s.p1 - s.p0
            let isWrap = closed && i == segments.count - 1
            if isWrap {
                anchors[0].inHandle = s.p2 - s.p3
            } else {
                anchors.append(BezierAnchor(s.p3, inHandle: s.p2 - s.p3))
            }
        }
        self.init(id: id, anchors: anchors, closed: closed, kind: kind)
    }

    public var segmentCount: Int { anchors.count < 2 ? 0 : (closed ? anchors.count : anchors.count - 1) }

    public func segment(_ i: Int) -> CubicBezier {
        let a = anchors[i], b = anchors[(i + 1) % anchors.count]
        return CubicBezier(a.position, a.position + a.outHandle, b.position + b.inHandle, b.position)
    }

    public var segments: [CubicBezier] { (0..<segmentCount).map(segment) }

    /// Polyline approximation. For closed paths the first point is not repeated at the end.
    public func polyline(samplesPerSegment: Int = 24) -> [Vec2] {
        if anchors.count == 1 { return [anchors[0].position] }
        var out: [Vec2] = []
        let segs = segments
        for (i, s) in segs.enumerated() {
            let isLast = i == segs.count - 1
            s.flatten(into: &out, samples: samplesPerSegment, dropLast: !isLast || closed)
        }
        return out
    }

    public var length: Float { segments.reduce(0) { $0 + $1.length } }

    public var bounds: (min: Vec2, max: Vec2) {
        let pts = polyline(samplesPerSegment: 12)
        var lo = Vec2(repeating: .greatestFiniteMagnitude), hi = -lo
        for p in pts { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }

    public var centroid: Vec2 {
        let pts = polyline(samplesPerSegment: 8)
        guard !pts.isEmpty else { return .zero }
        return pts.reduce(.zero, +) / Float(pts.count)
    }

    /// Applies an arbitrary point map to anchors and handle tips (exact for affine maps).
    public mutating func transform(_ f: (Vec2) -> Vec2) {
        for i in anchors.indices {
            let a = anchors[i]
            let p = f(a.position)
            anchors[i] = BezierAnchor(p, inHandle: f(a.position + a.inHandle) - p, outHandle: f(a.position + a.outHandle) - p)
        }
    }

    public func transformed(_ f: (Vec2) -> Vec2) -> SketchPath {
        var c = self; c.transform(f); return c
    }

    /// Distance from `q` to the curve.
    public func distance(to q: Vec2) -> Float {
        var best = Float.greatestFiniteMagnitude
        for s in segments {
            let t = s.closestParameter(to: q)
            best = min(best, simd_distance(s.point(at: t), q))
        }
        if segments.isEmpty, let a = anchors.first { best = simd_distance(a.position, q) }
        return best
    }

    // MARK: Primitive builders

    /// Exact-tangent 4-arc circle (handle length κ·r).
    public static func circle(center c: Vec2, radius r: Float) -> SketchPath {
        let k: Float = 0.5522847498 * r
        let anchors = [
            BezierAnchor(c + Vec2(r, 0), inHandle: Vec2(0, -k), outHandle: Vec2(0, k)),
            BezierAnchor(c + Vec2(0, r), inHandle: Vec2(k, 0), outHandle: Vec2(-k, 0)),
            BezierAnchor(c + Vec2(-r, 0), inHandle: Vec2(0, k), outHandle: Vec2(0, -k)),
            BezierAnchor(c + Vec2(0, -r), inHandle: Vec2(-k, 0), outHandle: Vec2(k, 0)),
        ]
        return SketchPath(anchors: anchors, closed: true, kind: .circle)
    }

    public static func rectangle(_ a: Vec2, _ b: Vec2) -> SketchPath {
        let lo = simd_min(a, b), hi = simd_max(a, b)
        let pts = [lo, Vec2(hi.x, lo.y), hi, Vec2(lo.x, hi.y)]
        return polyline(pts, closed: true, kind: .rectangle)
    }

    /// Straight-segment path where handles sit at the thirds (keeps uniform speed).
    public static func polyline(_ pts: [Vec2], closed: Bool, kind: Kind = .polyline) -> SketchPath {
        var segs: [CubicBezier] = []
        for i in 0..<(pts.count - 1) { segs.append(.line(pts[i], pts[i + 1])) }
        if closed, let f = pts.first, let l = pts.last, simd_distance(f, l) > 1e-4 { segs.append(.line(l, f)) }
        if pts.count == 1 { return SketchPath(anchors: [BezierAnchor(pts[0])], closed: false, kind: kind) }
        return SketchPath(segments: segs, closed: closed, kind: kind)
    }

    /// Centripetal-free uniform Catmull–Rom through `pts`, converted to cubic Béziers.
    public static func smoothCurve(through pts: [Vec2], closed: Bool) -> [CubicBezier] {
        guard pts.count >= 2 else { return [] }
        let n = pts.count
        func p(_ i: Int) -> Vec2 {
            if closed { return pts[(i % n + n) % n] }
            if i < 0 { return pts[0] * 2 - pts[1] }
            if i >= n { return pts[n - 1] * 2 - pts[n - 2] }
            return pts[i]
        }
        var segs: [CubicBezier] = []
        let count = closed ? n : n - 1
        for i in 0..<count {
            let p0 = p(i - 1), p1 = p(i), p2 = p(i + 1), p3 = p(i + 2)
            segs.append(CubicBezier(p1, p1 + (p2 - p0) / 6, p2 - (p3 - p1) / 6, p2))
        }
        return segs
    }
}

// MARK: - Sketch (one per plane)

public struct Sketch: Codable, Equatable, Sendable {
    public var paths: [SketchPath]
    public var constraints: [SketchConstraint]

    public init(paths: [SketchPath] = [], constraints: [SketchConstraint] = []) {
        self.paths = paths; self.constraints = constraints
    }

    public var isEmpty: Bool { paths.isEmpty }

    public var bounds: (min: Vec2, max: Vec2)? {
        guard !paths.isEmpty else { return nil }
        var lo = Vec2(repeating: .greatestFiniteMagnitude), hi = -lo
        for p in paths {
            let b = p.bounds
            lo = simd_min(lo, b.min); hi = simd_max(hi, b.max)
        }
        return (lo, hi)
    }

    public func pathIndex(_ id: UUID) -> Int? { paths.firstIndex { $0.id == id } }

    public mutating func transformAll(_ f: (Vec2) -> Vec2) {
        for i in paths.indices { paths[i].transform(f) }
    }
}

// MARK: - Freehand stroke → Bézier fitting

/// Turns noisy pointer samples into a small number of smooth cubic Béziers.
///
/// Pipeline: drop near-duplicate samples → light Laplacian smoothing → corner detection →
/// Philip J. Schneider's least-squares fitter ("An Algorithm for Automatically Fitting
/// Digitized Curves", Graphics Gems 1990) on each corner-to-corner run.
public enum BezierFitter {

    public struct Options: Sendable {
        public var tolerance: Float = 0.9          // max deviation (mm)
        public var cornerAngle: Float = 0.95       // radians (~55°) turn counts as a corner
        public var smoothingPasses: Int = 2
        public var minSpacing: Float = 0.6         // mm between kept samples
        public init() {}
    }

    public static func fit(_ input: [Vec2], closed: Bool, options: Options = Options()) -> [CubicBezier] {
        var pts = resample(input, spacing: options.minSpacing)
        if closed, let f = pts.first, let l = pts.last, simd_distance(f, l) < options.minSpacing * 2 { pts.removeLast() }
        guard pts.count >= 2 else { return [] }
        if pts.count == 2 { return [.line(pts[0], pts[1])] }

        pts = smooth(pts, passes: options.smoothingPasses, closed: closed)
        var corners = detectCorners(pts, angle: options.cornerAngle, closed: closed)

        if closed {
            // Rotate so the loop starts at a corner (or anywhere if smooth), then close it.
            if let first = corners.first, first != 0 {
                pts = Array(pts[first...] + pts[..<first])
                corners = corners.map { ($0 - first + pts.count) % pts.count }.sorted()
            }
            pts.append(pts[0])
        }
        var breaks = [0] + corners.filter { $0 > 0 && $0 < pts.count - 1 } + [pts.count - 1]
        breaks = Array(Set(breaks)).sorted()

        let smoothLoop = closed && corners.isEmpty
        var out: [CubicBezier] = []
        for k in 0..<(breaks.count - 1) {
            let a = breaks[k], b = breaks[k + 1]
            if b - a < 1 { continue }
            var t1 = leftTangent(pts, a, b)
            var t2 = rightTangent(pts, a, b)
            if smoothLoop {
                // Continuous tangent across the closing point.
                let n = pts.count - 1
                let joint = (pts[1] - pts[n - 1]).safeNormalized
                t1 = joint; t2 = -joint
            }
            fitCubic(pts, a, b, t1, t2, options.tolerance * options.tolerance, &out)
        }
        return out
    }

    // MARK: Preprocessing

    static func resample(_ pts: [Vec2], spacing: Float) -> [Vec2] {
        guard var last = pts.first else { return [] }
        var out = [last]
        for p in pts.dropFirst() where simd_distance(p, last) >= spacing {
            out.append(p); last = p
        }
        if let l = pts.last, out.count > 1, simd_distance(l, out[out.count - 1]) > 1e-4 { out.append(l) }
        else if let l = pts.last, out.count == 1, simd_distance(l, out[0]) > 1e-4 { out.append(l) }
        return out
    }

    static func smooth(_ pts: [Vec2], passes: Int, closed: Bool) -> [Vec2] {
        var p = pts
        let n = p.count
        guard n > 3 else { return p }
        for _ in 0..<passes {
            var q = p
            for i in 0..<n {
                if !closed && (i == 0 || i == n - 1) { continue }
                let a = p[(i - 1 + n) % n], b = p[(i + 1) % n]
                q[i] = p[i] * 0.5 + (a + b) * 0.25
            }
            p = q
        }
        return p
    }

    static func detectCorners(_ pts: [Vec2], angle: Float, closed: Bool) -> [Int] {
        let n = pts.count
        guard n > 6 else { return [] }
        let w = max(2, min(6, n / 10))
        var scores = [Float](repeating: 0, count: n)
        for i in 0..<n {
            if !closed && (i < w || i >= n - w) { continue }
            let a = pts[(i - w + n) % n], b = pts[i], c = pts[(i + w) % n]
            let d1 = (b - a).safeNormalized, d2 = (c - b).safeNormalized
            scores[i] = acos(clamp(simd_dot(d1, d2), -1, 1))
        }
        var corners: [Int] = []
        for i in 0..<n where scores[i] > angle {
            // Local maximum within the window.
            var isMax = true
            for k in 1...w where scores[(i + k) % n] > scores[i] || scores[(i - k + n) % n] >= scores[i] + 1e-6 {
                isMax = false; break
            }
            if isMax { corners.append(i) }
        }
        return corners
    }

    // MARK: Schneider fitter

    static func leftTangent(_ d: [Vec2], _ a: Int, _ b: Int) -> Vec2 {
        let k = min(a + 2, b)
        return (d[k] - d[a]).safeNormalized
    }

    static func rightTangent(_ d: [Vec2], _ a: Int, _ b: Int) -> Vec2 {
        let k = max(b - 2, a)
        return (d[k] - d[b]).safeNormalized
    }

    static func fitCubic(_ d: [Vec2], _ first: Int, _ last: Int, _ t1: Vec2, _ t2: Vec2, _ errSq: Float, _ out: inout [CubicBezier]) {
        let nPts = last - first + 1
        if nPts == 2 {
            let dist = simd_distance(d[last], d[first]) / 3
            out.append(CubicBezier(d[first], d[first] + t1 * dist, d[last] + t2 * dist, d[last]))
            return
        }
        var u = chordLengthParameterize(d, first, last)
        var bez = generateBezier(d, first, last, u, t1, t2)
        var (maxErr, split) = maxError(d, first, last, bez, u)
        if maxErr < errSq { out.append(bez); return }

        if maxErr < errSq * 16 {
            for _ in 0..<6 {
                let uPrime = reparameterize(d, first, last, u, bez)
                bez = generateBezier(d, first, last, uPrime, t1, t2)
                (maxErr, split) = maxError(d, first, last, bez, uPrime)
                if maxErr < errSq { out.append(bez); return }
                u = uPrime
            }
        }
        split = clamp(split, first + 1, last - 1)
        let tCenter = (d[split - 1] - d[split + 1]).safeNormalized
        fitCubic(d, first, split, t1, tCenter, errSq, &out)
        fitCubic(d, split, last, -tCenter, t2, errSq, &out)
    }

    static func chordLengthParameterize(_ d: [Vec2], _ first: Int, _ last: Int) -> [Float] {
        var u: [Float] = [0]
        for i in (first + 1)...last { u.append(u[u.count - 1] + simd_distance(d[i], d[i - 1])) }
        let total = u[u.count - 1]
        return total > 0 ? u.map { $0 / total } : u
    }

    static func generateBezier(_ d: [Vec2], _ first: Int, _ last: Int, _ u: [Float], _ t1: Vec2, _ t2: Vec2) -> CubicBezier {
        let p0 = d[first], p3 = d[last]
        var c00: Float = 0, c01: Float = 0, c11: Float = 0, x0: Float = 0, x1: Float = 0
        for i in 0..<u.count {
            let t = u[i], mt = 1 - t
            let b0 = mt * mt * mt, b1 = 3 * mt * mt * t, b2 = 3 * mt * t * t, b3 = t * t * t
            let a0 = t1 * b1, a1 = t2 * b2
            c00 += simd_dot(a0, a0); c01 += simd_dot(a0, a1); c11 += simd_dot(a1, a1)
            let tmp = d[first + i] - (p0 * (b0 + b1) + p3 * (b2 + b3))
            x0 += simd_dot(a0, tmp); x1 += simd_dot(a1, tmp)
        }
        let det = c00 * c11 - c01 * c01
        let segLen = simd_distance(p3, p0)
        var alphaL: Float = 0, alphaR: Float = 0
        if abs(det) > 1e-12 {
            alphaL = (x0 * c11 - x1 * c01) / det
            alphaR = (c00 * x1 - c01 * x0) / det
        }
        let eps = 1e-6 * segLen
        if alphaL < eps || alphaR < eps || alphaL > segLen * 2 || alphaR > segLen * 2 {
            let dist = segLen / 3
            return CubicBezier(p0, p0 + t1 * dist, p3 + t2 * dist, p3)
        }
        return CubicBezier(p0, p0 + t1 * alphaL, p3 + t2 * alphaR, p3)
    }

    static func maxError(_ d: [Vec2], _ first: Int, _ last: Int, _ bez: CubicBezier, _ u: [Float]) -> (Float, Int) {
        var maxDist: Float = 0
        var split = (last - first + 1) / 2 + first
        for i in (first + 1)..<last {
            let dist = simd_length_squared(bez.point(at: u[i - first]) - d[i])
            if dist >= maxDist { maxDist = dist; split = i }
        }
        return (maxDist, split)
    }

    static func reparameterize(_ d: [Vec2], _ first: Int, _ last: Int, _ u: [Float], _ bez: CubicBezier) -> [Float] {
        (first...last).map { i in
            let t = u[i - first]
            let q = bez.point(at: t) - d[i]
            let q1 = bez.derivative(at: t), q2 = bez.secondDerivative(at: t)
            let den = simd_dot(q1, q1) + simd_dot(q, q2)
            if abs(den) < 1e-12 { return t }
            return clamp(t - simd_dot(q, q1) / den, 0, 1)
        }
    }
}
