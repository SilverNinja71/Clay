import Foundation
import simd

public typealias Vec2 = SIMD2<Float>
public typealias Vec3 = SIMD3<Float>
public typealias Vec4 = SIMD4<Float>
public typealias Mat4 = simd_float4x4

// MARK: - Scalar helpers

@inlinable public func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
@inlinable public func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inlinable public func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = clamp((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
}
@inlinable public func degrees(_ r: Float) -> Float { r * 180 / .pi }
@inlinable public func radians(_ d: Float) -> Float { d * .pi / 180 }

/// Shortest signed angle from `a` to `b` (radians).
@inlinable public func angleDelta(_ a: Float, _ b: Float) -> Float {
    var d = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
    if d > .pi { d -= 2 * .pi }
    if d < -.pi { d += 2 * .pi }
    return d
}

// MARK: - Vector helpers

public extension SIMD3 where Scalar == Float {
    var safeNormalized: Vec3 {
        let l = simd_length(self)
        return l > 1e-12 ? self / l : .zero
    }
    var xz: Vec2 { Vec2(x, z) }
    init(_ v: Vec2, z: Float) { self.init(v.x, v.y, z) }
}

public extension SIMD2 where Scalar == Float {
    var safeNormalized: Vec2 {
        let l = simd_length(self)
        return l > 1e-12 ? self / l : .zero
    }
    /// 2D cross product (z of the 3D cross).
    func cross(_ o: Vec2) -> Float { x * o.y - y * o.x }
    var perpendicular: Vec2 { Vec2(-y, x) }
}

/// Any unit vector perpendicular to `n`.
public func anyPerpendicular(_ n: Vec3) -> Vec3 {
    let a: Vec3 = abs(n.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
    return simd_cross(n, a).safeNormalized
}

// MARK: - Matrices (right-handed, Metal clip z in [0, 1])

public extension simd_float4x4 {
    static let identity = matrix_identity_float4x4

    static func translation(_ t: Vec3) -> Mat4 {
        var m = matrix_identity_float4x4
        m.columns.3 = Vec4(t.x, t.y, t.z, 1)
        return m
    }

    static func scale(_ s: Vec3) -> Mat4 { Mat4(diagonal: Vec4(s.x, s.y, s.z, 1)) }

    static func rotation(angle: Float, axis: Vec3) -> Mat4 {
        Mat4(simd_quatf(angle: angle, axis: axis.safeNormalized))
    }

    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> Mat4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return Mat4(columns: (Vec4(x, 0, 0, 0), Vec4(0, y, 0, 0), Vec4(0, 0, z, -1), Vec4(0, 0, z * near, 0)))
    }

    static func orthographic(halfWidth: Float, halfHeight: Float, near: Float, far: Float) -> Mat4 {
        let sz = 1 / (near - far)
        return Mat4(columns: (Vec4(1 / halfWidth, 0, 0, 0),
                              Vec4(0, 1 / halfHeight, 0, 0),
                              Vec4(0, 0, sz, 0),
                              Vec4(0, 0, near * sz, 1)))
    }

    static func lookAt(eye: Vec3, target: Vec3, up: Vec3) -> Mat4 {
        let f = (target - eye).safeNormalized
        let s = simd_cross(f, up).safeNormalized
        let u = simd_cross(s, f)
        return Mat4(columns: (Vec4(s.x, u.x, -f.x, 0),
                              Vec4(s.y, u.y, -f.y, 0),
                              Vec4(s.z, u.z, -f.z, 0),
                              Vec4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    func transformPoint(_ p: Vec3) -> Vec3 {
        let r = self * Vec4(p.x, p.y, p.z, 1)
        return Vec3(r.x, r.y, r.z) / (abs(r.w) > 1e-12 ? r.w : 1)
    }

    func transformDirection(_ d: Vec3) -> Vec3 {
        let r = self * Vec4(d.x, d.y, d.z, 0)
        return Vec3(r.x, r.y, r.z)
    }

    /// Upper-left 3x3 inverse-transpose, used for transforming normals.
    var normalMatrix: simd_float3x3 {
        let m = simd_float3x3(Vec3(columns.0.x, columns.0.y, columns.0.z),
                              Vec3(columns.1.x, columns.1.y, columns.1.z),
                              Vec3(columns.2.x, columns.2.y, columns.2.z))
        return m.inverse.transpose
    }
}

// MARK: - Rays and boxes

public struct Ray: Sendable {
    public var origin: Vec3
    public var direction: Vec3
    public init(origin: Vec3, direction: Vec3) {
        self.origin = origin
        self.direction = direction.safeNormalized
    }
    public func at(_ t: Float) -> Vec3 { origin + direction * t }

    /// Intersection with the plane through `point` with normal `normal`.
    public func intersectPlane(point: Vec3, normal: Vec3) -> Vec3? {
        let denom = simd_dot(normal, direction)
        guard abs(denom) > 1e-6 else { return nil }
        let t = simd_dot(point - origin, normal) / denom
        return t >= 0 ? at(t) : nil
    }
}

/// Möller–Trumbore ray/triangle intersection. Returns distance along the ray.
@inlinable public func rayTriangle(_ o: Vec3, _ d: Vec3, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> Float? {
    let e1 = b - a, e2 = c - a
    let p = simd_cross(d, e2)
    let det = simd_dot(e1, p)
    if abs(det) < 1e-9 { return nil }
    let inv = 1 / det
    let s = o - a
    let u = simd_dot(s, p) * inv
    if u < 0 || u > 1 { return nil }
    let q = simd_cross(s, e1)
    let v = simd_dot(d, q) * inv
    if v < 0 || u + v > 1 { return nil }
    let t = simd_dot(e2, q) * inv
    return t > 1e-5 ? t : nil
}

public struct AABB: Equatable, Sendable {
    public var min: Vec3
    public var max: Vec3
    public init(min: Vec3, max: Vec3) { self.min = min; self.max = max }
    public static let empty = AABB(min: Vec3(repeating: .greatestFiniteMagnitude), max: Vec3(repeating: -.greatestFiniteMagnitude))
    public var isEmpty: Bool { min.x > max.x }
    public var center: Vec3 { (min + max) * 0.5 }
    public var size: Vec3 { isEmpty ? .zero : max - min }
    public var radius: Float { simd_length(size) * 0.5 }
    public mutating func include(_ p: Vec3) {
        min = simd_min(min, p)
        max = simd_max(max, p)
    }
    public init<S: Sequence>(points: S) where S.Element == Vec3 {
        var b = AABB.empty
        for p in points { b.include(p) }
        self = b
    }
}

// MARK: - Small dense linear algebra (for the constraint solver)

public enum LinearAlgebra {
    /// Solves A x = b with Gaussian elimination and partial pivoting. A is row-major n×n.
    public static func solve(_ a: [Double], _ b: [Double], n: Int) -> [Double]? {
        var m = a
        var x = b
        for col in 0..<n {
            var pivot = col
            var best = abs(m[col * n + col])
            for r in (col + 1)..<max(col + 1, n) where abs(m[r * n + col]) > best {
                best = abs(m[r * n + col]); pivot = r
            }
            if best < 1e-14 { return nil }
            if pivot != col {
                for k in 0..<n { m.swapAt(col * n + k, pivot * n + k) }
                x.swapAt(col, pivot)
            }
            let inv = 1 / m[col * n + col]
            for r in (col + 1)..<max(col + 1, n) {
                let f = m[r * n + col] * inv
                if f == 0 { continue }
                for k in col..<n { m[r * n + k] -= f * m[col * n + k] }
                x[r] -= f * x[col]
            }
        }
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = x[r]
            for k in (r + 1)..<max(r + 1, n) { s -= m[r * n + k] * x[k] }
            x[r] = s / m[r * n + r]
        }
        return x
    }
}

// MARK: - Codable helpers

/// simd_quatf is not Codable; transforms store Euler angles in degrees instead.
public func eulerMatrix(degrees e: Vec3) -> Mat4 {
    Mat4.rotation(angle: radians(e.y), axis: Vec3(0, 1, 0)) *
    Mat4.rotation(angle: radians(e.x), axis: Vec3(1, 0, 0)) *
    Mat4.rotation(angle: radians(e.z), axis: Vec3(0, 0, 1))
}

/// Unique, monotonically increasing revision numbers (used to know when GPU buffers are stale).
public enum Revision {
    private static var counter: UInt64 = 0
    private static let lock = NSLock()
    public static func next() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return counter
    }
}
