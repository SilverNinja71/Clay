import Foundation
import simd

// MARK: - Units & numeric entry

public enum LengthUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case mm, cm, m, inch

    public var id: String { rawValue }
    public var symbol: String { self == .inch ? "in" : rawValue }
    /// Millimetres per unit (internal model space is millimetres).
    public var millimetres: Float {
        switch self { case .mm: 1; case .cm: 10; case .m: 1000; case .inch: 25.4 }
    }
    public var decimals: Int {
        switch self { case .mm: 1; case .cm: 2; case .m: 4; case .inch: 3 }
    }
    public func format(_ mm: Float, withSymbol: Bool = true) -> String {
        let v = mm / millimetres
        let s = String(format: "%.\(decimals)f", v)
        return withSymbol ? "\(s) \(symbol)" : s
    }
}

/// Parses numeric input such as `65`, `6.5cm`, `2 in`, `50 + 15`, `(120/2) mm`.
/// Unitless numbers use `defaultUnit`. Returns millimetres.
public enum UnitExpression {
    public static func evaluate(_ text: String, defaultUnit: LengthUnit) -> Float? {
        var p = Parser(chars: Array(text.lowercased()), unit: defaultUnit)
        guard let v = p.expression() else { return nil }
        p.skipSpace()
        return p.i == p.chars.count && v.isFinite ? Float(v) : nil
    }

    struct Parser {
        let chars: [Character]
        /// Millimetres per unitless number; a unit after ")" applies to the numbers inside.
        var unitStack: [Double]
        var i = 0
        init(chars: [Character], unit: LengthUnit) { self.chars = chars; self.unitStack = [Double(unit.millimetres)] }

        mutating func skipSpace() { while i < chars.count && chars[i] == " " { i += 1 } }

        mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while true {
                skipSpace()
                guard i < chars.count, chars[i] == "+" || chars[i] == "-" else { return v }
                let op = chars[i]; i += 1
                guard let r = term() else { return nil }
                v = op == "+" ? v + r : v - r
            }
        }

        mutating func term() -> Double? {
            guard var v = factor() else { return nil }
            while true {
                skipSpace()
                guard i < chars.count, chars[i] == "*" || chars[i] == "/" || chars[i] == "×" else { return v }
                let op = chars[i]; i += 1
                // Right operands of * and / are plain factors (unitless scale).
                guard let r = factor(scalar: true) else { return nil }
                if op == "/" { guard r != 0 else { return nil }; v /= r } else { v *= r }
            }
        }

        mutating func factor(scalar: Bool = false) -> Double? {
            skipSpace()
            guard i < chars.count else { return nil }
            if chars[i] == "-" { i += 1; return factor(scalar: scalar).map { -$0 } }
            if chars[i] == "(" {
                // Find the matching ")" and peek at the unit that follows it.
                var depth = 0, j = i
                while j < chars.count {
                    if chars[j] == "(" { depth += 1 }
                    if chars[j] == ")" { depth -= 1; if depth == 0 { break } }
                    j += 1
                }
                guard j < chars.count else { return nil }
                let saved = i
                i = j + 1
                let groupUnit = unitSuffix(default: unitStack[unitStack.count - 1])
                let afterSuffix = i
                i = saved + 1
                unitStack.append(scalar ? 1 : groupUnit)
                defer { unitStack.removeLast() }
                guard let v = expression() else { return nil }
                skipSpace()
                guard i == j else { return nil }
                i = afterSuffix
                return v
            }
            var s = ""
            while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "," {
                s.append(chars[i] == "," ? "." : chars[i]); i += 1
            }
            guard let n = Double(s) else { return nil }
            if scalar { return n }
            return n * unitSuffix(default: unitStack[unitStack.count - 1])
        }

        /// Consumes an optional unit suffix; returns millimetres per unit.
        mutating func unitSuffix(default d: Double) -> Double {
            skipSpace()
            let rest = String(chars[i...])
            for (token, mm) in [("mm", 1.0), ("cm", 10.0), ("in", 25.4), ("\"", 25.4), ("ft", 304.8), ("m", 1000.0)] where rest.hasPrefix(token) {
                i += token.count
                return mm
            }
            return d
        }
    }
}

// MARK: - Sketch constraints

public struct AnchorRef: Codable, Hashable, Sendable {
    public var path: UUID
    public var index: Int
    public init(path: UUID, index: Int) { self.path = path; self.index = index }
}

public enum SketchConstraint: Codable, Equatable, Sendable {
    case distance(AnchorRef, AnchorRef, Float)
    case horizontalDistance(AnchorRef, AnchorRef, Float)
    case verticalDistance(AnchorRef, AnchorRef, Float)
    case horizontal(AnchorRef, AnchorRef)
    case vertical(AnchorRef, AnchorRef)
    case parallel(AnchorRef, AnchorRef, AnchorRef, AnchorRef)
    case perpendicular(AnchorRef, AnchorRef, AnchorRef, AnchorRef)
    case angle(AnchorRef, AnchorRef, AnchorRef, AnchorRef, Float)   // degrees
    case equalLength(AnchorRef, AnchorRef, AnchorRef, AnchorRef)
    case coincident(AnchorRef, AnchorRef)
    case fixed(AnchorRef, Vec2)
    case radius(UUID, Float)
    case concentric(UUID, UUID)
    case tangent(AnchorRef)

    public var title: String {
        switch self {
        case .distance: "Distance"
        case .horizontalDistance: "Horizontal distance"
        case .verticalDistance: "Vertical distance"
        case .horizontal: "Horizontal"
        case .vertical: "Vertical"
        case .parallel: "Parallel"
        case .perpendicular: "Perpendicular"
        case .angle: "Angle"
        case .equalLength: "Equal"
        case .coincident: "Coincident"
        case .fixed: "Fixed"
        case .radius: "Radius"
        case .concentric: "Concentric"
        case .tangent: "Tangent"
        }
    }

    public var symbol: String {
        switch self {
        case .distance, .horizontalDistance, .verticalDistance: "ruler"
        case .horizontal: "arrow.left.and.right"
        case .vertical: "arrow.up.and.down"
        case .parallel: "equal"
        case .perpendicular: "angle"
        case .angle: "angle"
        case .equalLength: "equal.square"
        case .coincident: "smallcircle.filled.circle"
        case .fixed: "lock.fill"
        case .radius: "circle.circle"
        case .concentric: "circle.dotted"
        case .tangent: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    /// Driving value (for dimensional constraints), editable from a callout.
    public var value: Float? {
        switch self {
        case .distance(_, _, let v), .horizontalDistance(_, _, let v), .verticalDistance(_, _, let v), .radius(_, let v): v
        case .angle(_, _, _, _, let v): v
        default: nil
        }
    }

    public func withValue(_ v: Float) -> SketchConstraint {
        switch self {
        case .distance(let a, let b, _): .distance(a, b, v)
        case .horizontalDistance(let a, let b, _): .horizontalDistance(a, b, v)
        case .verticalDistance(let a, let b, _): .verticalDistance(a, b, v)
        case .radius(let p, _): .radius(p, v)
        case .angle(let a, let b, let c, let d, _): .angle(a, b, c, d, v)
        default: self
        }
    }

    var anchorRefs: [AnchorRef] {
        switch self {
        case .distance(let a, let b, _), .horizontalDistance(let a, let b, _), .verticalDistance(let a, let b, _),
             .horizontal(let a, let b), .vertical(let a, let b), .coincident(let a, let b):
            [a, b]
        case .parallel(let a, let b, let c, let d), .perpendicular(let a, let b, let c, let d),
             .angle(let a, let b, let c, let d, _), .equalLength(let a, let b, let c, let d):
            [a, b, c, d]
        case .fixed(let a, _), .tangent(let a): [a]
        case .radius, .concentric: []
        }
    }

    var circlePaths: [UUID] {
        switch self {
        case .radius(let p, _): [p]
        case .concentric(let a, let b): [a, b]
        default: []
        }
    }
}

public struct SolveReport: Equatable, Sendable {
    public var converged: Bool
    public var iterations: Int
    public var residual: Float
    /// Remaining degrees of freedom among the constrained anchors (0 = fully constrained).
    public var degreesOfFreedom: Int
}

/// Geometric constraint solver for 2D sketches (Levenberg–Marquardt with a numeric Jacobian).
///
/// Unknowns are the positions of the anchors that constraints mention; everything else stays
/// fixed. Damping keeps under-constrained sketches close to where the user drew them.
public enum ConstraintSolver {

    @discardableResult
    public static func solve(_ sketch: inout Sketch, maxIterations: Int = 60) -> SolveReport {
        let cons = sketch.constraints
        guard !cons.isEmpty else { return SolveReport(converged: true, iterations: 0, residual: 0, degreesOfFreedom: 0) }

        // Collect unknowns.
        var refs: [AnchorRef] = []
        var refIndex: [AnchorRef: Int] = [:]
        func add(_ r: AnchorRef) {
            guard refIndex[r] == nil, let pi = sketch.pathIndex(r.path), r.index < sketch.paths[pi].anchors.count else { return }
            refIndex[r] = refs.count; refs.append(r)
        }
        for c in cons {
            if case .tangent = c { continue }
            if case .fixed = c { continue }
            c.anchorRefs.forEach(add)
            for pid in c.circlePaths {
                if let pi = sketch.pathIndex(pid) { for k in sketch.paths[pi].anchors.indices { add(AnchorRef(path: pid, index: k)) } }
            }
        }
        // Fixed anchors are unknowns pinned by their residual, so they still interact with the rest.
        for c in cons { if case .fixed(let a, _) = c { add(a) } }

        let base = sketch
        func basePosition(_ r: AnchorRef) -> Vec2 {
            guard let pi = base.pathIndex(r.path), r.index < base.paths[pi].anchors.count else { return .zero }
            return base.paths[pi].anchors[r.index].position
        }
        func position(_ r: AnchorRef, _ x: [Double]) -> Vec2 {
            if let k = refIndex[r] { return Vec2(Float(x[2 * k]), Float(x[2 * k + 1])) }
            return basePosition(r)
        }
        func circleCentroid(_ pid: UUID, _ x: [Double]) -> (Vec2, [Vec2]) {
            guard let pi = base.pathIndex(pid) else { return (.zero, []) }
            let pts = base.paths[pi].anchors.indices.map { position(AnchorRef(path: pid, index: $0), x) }
            return (pts.reduce(.zero, +) / Float(max(pts.count, 1)), pts)
        }

        var x0: [Double] = []
        for r in refs { let p = basePosition(r); x0 += [Double(p.x), Double(p.y)] }
        if x0.isEmpty { return SolveReport(converged: true, iterations: 0, residual: 0, degreesOfFreedom: 0) }

        // Orientation signs for signed distances are taken from the starting sketch.
        func sign(_ v: Float) -> Float { v < 0 ? -1 : 1 }
        let angleWeight: Float = 40 // mm per radian, balances angular and linear residuals

        func residuals(_ x: [Double]) -> [Double] {
            var r: [Float] = []
            for c in cons {
                switch c {
                case .distance(let a, let b, let v):
                    r.append(simd_distance(position(a, x), position(b, x)) - v)
                case .horizontalDistance(let a, let b, let v):
                    let s = sign(position(b, x0).x - position(a, x0).x)
                    r.append((position(b, x).x - position(a, x).x) - s * v)
                case .verticalDistance(let a, let b, let v):
                    let s = sign(position(b, x0).y - position(a, x0).y)
                    r.append((position(b, x).y - position(a, x).y) - s * v)
                case .horizontal(let a, let b):
                    r.append(position(b, x).y - position(a, x).y)
                case .vertical(let a, let b):
                    r.append(position(b, x).x - position(a, x).x)
                case .parallel(let a, let b, let c2, let d):
                    let u = (position(b, x) - position(a, x)).safeNormalized, w = (position(d, x) - position(c2, x)).safeNormalized
                    r.append(u.cross(w) * angleWeight)
                case .perpendicular(let a, let b, let c2, let d):
                    let u = (position(b, x) - position(a, x)).safeNormalized, w = (position(d, x) - position(c2, x)).safeNormalized
                    r.append(simd_dot(u, w) * angleWeight)
                case .angle(let a, let b, let c2, let d, let deg):
                    let u = (position(b, x) - position(a, x)).safeNormalized, w = (position(d, x) - position(c2, x)).safeNormalized
                    let ang = atan2(u.cross(w), simd_dot(u, w))
                    r.append(angleDelta(radians(deg), abs(ang)) * angleWeight)
                case .equalLength(let a, let b, let c2, let d):
                    r.append(simd_distance(position(a, x), position(b, x)) - simd_distance(position(c2, x), position(d, x)))
                case .coincident(let a, let b):
                    let d = position(a, x) - position(b, x); r += [d.x, d.y]
                case .fixed(let a, let p):
                    let d = (position(a, x) - p) * 10; r += [d.x, d.y]
                case .radius(let pid, let v):
                    let (cen, pts) = circleCentroid(pid, x)
                    for p in pts { r.append(simd_distance(p, cen) - v) }
                case .concentric(let p1, let p2):
                    let d = circleCentroid(p1, x).0 - circleCentroid(p2, x).0; r += [d.x, d.y]
                case .tangent:
                    break
                }
            }
            return r.map(Double.init)
        }

        var x = x0
        var r = residuals(x)
        var cost = r.reduce(0) { $0 + $1 * $1 }
        var lambda = 1e-3
        let n = x.count
        var iterations = 0
        while iterations < maxIterations && cost > 1e-10 {
            iterations += 1
            // Numeric Jacobian (m × n).
            let m = r.count
            var J = [Double](repeating: 0, count: m * n)
            let h = 1e-4
            for j in 0..<n {
                var xp = x; xp[j] += h
                let rp = residuals(xp)
                for i in 0..<m { J[i * n + j] = (rp[i] - r[i]) / h }
            }
            var A = [Double](repeating: 0, count: n * n)
            var g = [Double](repeating: 0, count: n)
            for i in 0..<m {
                for a in 0..<n where J[i * n + a] != 0 {
                    g[a] += J[i * n + a] * r[i]
                    for b in 0..<n { A[a * n + b] += J[i * n + a] * J[i * n + b] }
                }
            }
            var improved = false
            for _ in 0..<10 {
                var Ad = A
                for k in 0..<n { Ad[k * n + k] += lambda * (A[k * n + k] + 1e-6) + 1e-9 }
                guard let delta = LinearAlgebra.solve(Ad, g.map { -$0 }, n: n) else { lambda *= 10; continue }
                let xn = zip(x, delta).map { $0 + $1 }
                let rn = residuals(xn)
                let cn = rn.reduce(0) { $0 + $1 * $1 }
                if cn < cost {
                    x = xn; r = rn; cost = cn
                    lambda = max(lambda / 3, 1e-9)
                    improved = true
                    break
                }
                lambda *= 4
            }
            if !improved { break }
        }

        // Write back.
        for (k, ref) in refs.enumerated() {
            guard let pi = sketch.pathIndex(ref.path) else { continue }
            sketch.paths[pi].anchors[ref.index].position = Vec2(Float(x[2 * k]), Float(x[2 * k + 1]))
        }
        // Re-idealise constrained circles and apply tangent (smooth-anchor) constraints.
        for c in cons {
            for pid in c.circlePaths {
                guard let pi = sketch.pathIndex(pid), sketch.paths[pi].kind == .circle else { continue }
                let pts = sketch.paths[pi].anchors.map(\.position)
                let cen = pts.reduce(.zero, +) / Float(pts.count)
                let rad = pts.map { simd_distance($0, cen) }.reduce(0, +) / Float(pts.count)
                let id = sketch.paths[pi].id
                sketch.paths[pi] = SketchPath.circle(center: cen, radius: rad)
                sketch.paths[pi].id = id
            }
            if case .tangent(let a) = c, let pi = sketch.pathIndex(a.path), a.index < sketch.paths[pi].anchors.count {
                var an = sketch.paths[pi].anchors[a.index]
                let dir = (an.outHandle.safeNormalized - an.inHandle.safeNormalized).safeNormalized
                if dir != .zero {
                    an.outHandle = dir * max(simd_length(an.outHandle), 1)
                    an.inHandle = -dir * max(simd_length(an.inHandle), 1)
                    sketch.paths[pi].anchors[a.index] = an
                }
            }
        }
        let dof = max(0, n - r.count)
        return SolveReport(converged: cost < 1e-6, iterations: iterations, residual: Float(sqrt(cost)), degreesOfFreedom: dof)
    }
}

// MARK: - Model dimensions (driven through the sketches)

/// Dimensions of the lofted body that are *driving*: editing one edits the sketches, and the
/// timeline rebuilds everything downstream — the Fusion-style parametric loop.
public enum ProfileDimension: String, Codable, CaseIterable, Identifiable, Sendable {
    case height, width, depth, baseWidth, rimWidth

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .height: "Height"
        case .width: "Width"
        case .depth: "Depth"
        case .baseWidth: "Base ⌀"
        case .rimWidth: "Rim ⌀"
        }
    }
}

public enum ProfileDimensionSolver {

    static func level(_ d: ProfileDimension, _ fp: SilhouetteProfile) -> Float? {
        switch d {
        case .baseWidth: fp.vRange.lowerBound + fp.height * 1e-5
        case .rimWidth: fp.vRange.upperBound - fp.height * 1e-5
        default: nil
        }
    }

    public static func measure(_ d: ProfileDimension, front: Sketch, side: Sketch?) -> Float? {
        guard let fp = SilhouetteProfile(sketch: front) else { return nil }
        switch d {
        case .height: return fp.height
        case .width: return fp.maxWidth.width
        case .depth:
            if let side, let sp = SilhouetteProfile(sketch: side) { return sp.maxWidth.width }
            return fp.maxWidth.width
        case .baseWidth, .rimWidth:
            guard let v = level(d, fp), let e = fp.extent(at: v) else { return nil }
            return e.upperBound - e.lowerBound
        }
    }

    /// World-space endpoints for drawing the dimension callout (front plane at z = 0).
    public static func anchors(_ d: ProfileDimension, front: Sketch, side: Sketch?) -> (Vec3, Vec3)? {
        guard let fp = SilhouetteProfile(sketch: front) else { return nil }
        switch d {
        case .height:
            let e = fp.extent(at: fp.vRange.lowerBound + fp.height * 0.01) ?? 0...0
            let x = e.upperBound + 14
            return (Vec3(x, fp.vRange.lowerBound, 0), Vec3(x, fp.vRange.upperBound, 0))
        case .width:
            let (_, v) = fp.maxWidth
            guard let e = fp.extent(at: v) else { return nil }
            return (Vec3(e.lowerBound, v, 0), Vec3(e.upperBound, v, 0))
        case .depth:
            if let side, let sp = SilhouetteProfile(sketch: side), let e = sp.extent(at: sp.maxWidth.at) {
                return (SketchPlane.side.worldPoint(Vec2(e.lowerBound, sp.maxWidth.at)), SketchPlane.side.worldPoint(Vec2(e.upperBound, sp.maxWidth.at)))
            }
            return nil
        case .baseWidth, .rimWidth:
            guard let v = level(d, fp), let e = fp.extent(at: v) else { return nil }
            return (Vec3(e.lowerBound, v, 0), Vec3(e.upperBound, v, 0))
        }
    }

    /// Edits the sketches so that `d` measures `target` (mm). Returns false if impossible.
    @discardableResult
    public static func apply(_ d: ProfileDimension, target: Float, front: inout Sketch, side: inout Sketch?) -> Bool {
        guard target > 0.1, let fp = SilhouetteProfile(sketch: front), let current = measure(d, front: front, side: side), current > 1e-3 else { return false }
        let v0 = fp.vRange.lowerBound
        let cx = front.bounds.map { ($0.min.x + $0.max.x) / 2 } ?? 0
        let scx = side?.bounds.map { ($0.min.x + $0.max.x) / 2 } ?? 0
        switch d {
        case .height:
            let k = target / current
            front.transformAll { Vec2($0.x, v0 + ($0.y - v0) * k) }
            side?.transformAll { Vec2($0.x, v0 + ($0.y - v0) * k) }
        case .width:
            let k = target / current
            front.transformAll { Vec2(cx + ($0.x - cx) * k, $0.y) }
        case .depth:
            let k = target / current
            if side != nil { side!.transformAll { Vec2(scx + ($0.x - scx) * k, $0.y) } }
            else { front.transformAll { Vec2(cx + ($0.x - cx) * k, $0.y) } }
        case .baseWidth, .rimWidth:
            // Local radial warp around the base (or rim) with a smooth falloff band, solved with
            // the secant method so the measured width hits the target exactly.
            let h = fp.height, band = h * 0.38
            let fromBottom = d == .baseWidth
            let v1 = fp.vRange.upperBound
            func weight(_ y: Float) -> Float {
                fromBottom ? 1 - smoothstep(v0, v0 + band, y) : smoothstep(v1 - band, v1, y)
            }
            let f0 = front, s0 = side
            func warped(_ k: Float) -> (Sketch, Sketch?) {
                var f = f0, s = s0
                f.transformAll { p in Vec2(cx + (p.x - cx) * (1 + (k - 1) * weight(p.y)), p.y) }
                s?.transformAll { p in Vec2(scx + (p.x - scx) * (1 + (k - 1) * weight(p.y)), p.y) }
                return (f, s)
            }
            func err(_ k: Float) -> Float {
                let (f, s) = warped(k)
                return (measure(d, front: f, side: s) ?? 0) - target
            }
            var ka: Float = 1, kb = target / current
            var ea = err(ka), eb = err(kb)
            for _ in 0..<12 where abs(eb) > 1e-3 {
                let denom = eb - ea
                if abs(denom) < 1e-9 { break }
                let kn = max(0.02, kb - eb * (kb - ka) / denom)
                ka = kb; ea = eb; kb = kn; eb = err(kb)
            }
            (front, side) = warped(kb)
        }
        return true
    }
}
