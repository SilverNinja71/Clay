import Foundation
import simd

public typealias SketchCurve = SketchPath

/// A drawing sheet positioned anywhere in 3D (Shapr3D / Feather 3D style).
///
/// `origin`, `normal` and `up` define the plane's local axes: u runs along `right`
/// (up × normal), v along `up`. Its sketch is stored in those (u, v) millimetres, so the
/// same 2D tools, constraints and fitting work on every plane.
public struct SketchPlane: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var origin: Vec3
    public var normal: Vec3
    public var up: Vec3
    /// Width and height of the visible paper sheet (mm).
    public var size: Vec2
    public var sketch: Sketch
    public var isLocked: Bool
    public var isVisible: Bool
    /// Set for the built-in Front / Side / Top planes (their sketches drive the classic loft).
    public var standard: StandardPlane?

    public var curves: [SketchCurve] {
        get { sketch.paths }
        set { sketch.paths = newValue }
    }

    public init(id: UUID = UUID(), name: String, origin: Vec3, normal: Vec3, up: Vec3, size: Vec2 = Vec2(160, 160),
                sketch: Sketch = Sketch(), isLocked: Bool = false, isVisible: Bool = true, standard: StandardPlane? = nil) {
        self.id = id; self.name = name; self.origin = origin; self.normal = normal; self.up = up; self.size = size
        self.sketch = sketch; self.isLocked = isLocked; self.isVisible = isVisible; self.standard = standard
        orthonormalize()
    }

    /// The same plane with a different identity (used to keep plane id == timeline feature id).
    public func withID(_ newID: UUID) -> SketchPlane {
        SketchPlane(id: newID, name: name, origin: origin, normal: normal, up: up, size: size, sketch: sketch,
                    isLocked: isLocked, isVisible: isVisible, standard: standard)
    }

    /// The fixed orthographic planes, matching `StandardPlane.worldPoint`.
    public static func standard(_ s: StandardPlane, sketch: Sketch = Sketch(), id: UUID = UUID()) -> SketchPlane {
        let (n, u): (Vec3, Vec3) = switch s {
        case .front: (Vec3(0, 0, 1), Vec3(0, 1, 0))
        case .side: (Vec3(1, 0, 0), Vec3(0, 1, 0))
        case .top: (Vec3(0, 1, 0), Vec3(0, 0, -1))
        }
        return SketchPlane(id: id, name: "\(s.title) Sketch", origin: .zero, normal: n, up: u, size: Vec2(200, 200),
                           sketch: sketch, standard: s)
    }

    /// A plane through `origin` facing `normal`, with its up axis as close to world up as possible.
    public static func facing(_ normal: Vec3, at origin: Vec3, name: String, size: Vec2 = Vec2(160, 160)) -> SketchPlane {
        let n = normal.safeNormalized == .zero ? Vec3(0, 0, 1) : normal.safeNormalized
        let up: Vec3 = abs(n.y) > 0.95 ? Vec3(0, 0, n.y > 0 ? -1 : 1) : Vec3(0, 1, 0)
        return SketchPlane(name: name, origin: origin, normal: n, up: up, size: size)
    }

    // MARK: Frame

    public var right: Vec3 { simd_cross(up, normal).safeNormalized }

    /// Local (u, v) → world, optionally pushed `offset` mm along the normal.
    public func world(_ p: Vec2, offset: Float = 0) -> Vec3 {
        origin + right * p.x + up * p.y + normal * offset
    }

    /// World → local (u, v) (the normal component is dropped).
    public func local(_ w: Vec3) -> Vec2 {
        let d = w - origin
        return Vec2(simd_dot(d, right), simd_dot(d, up))
    }

    public func signedDistance(_ w: Vec3) -> Float { simd_dot(w - origin, normal) }

    /// Where a pointer ray meets the plane (from either side), in local coordinates.
    public func intersect(_ ray: Ray) -> (local: Vec2, distance: Float)? {
        let denom = simd_dot(normal, ray.direction)
        guard abs(denom) > 1e-6 else { return nil }
        let t = simd_dot(origin - ray.origin, normal) / denom
        guard t > 0 else { return nil }
        return (local(ray.at(t)), t)
    }

    /// The visible sheet in local coordinates. Built-in planes grow to fit their drawing.
    public var sheet: (min: Vec2, max: Vec2) {
        var lo = -size / 2, hi = size / 2
        if let b = sketch.bounds {
            lo = simd_min(lo, b.min - Vec2(15, 15))
            hi = simd_max(hi, b.max + Vec2(15, 15))
        }
        return (lo, hi)
    }

    public func sheetContains(_ p: Vec2, margin: Float = 0) -> Bool {
        let s = sheet
        return p.x >= s.min.x - margin && p.x <= s.max.x + margin && p.y >= s.min.y - margin && p.y <= s.max.y + margin
    }

    public var centerWorld: Vec3 {
        let s = sheet
        return world((s.min + s.max) / 2)
    }

    public mutating func orthonormalize() {
        normal = normal.safeNormalized
        if normal == .zero { normal = Vec3(0, 0, 1) }
        up = (up - normal * simd_dot(up, normal)).safeNormalized
        if up == .zero { up = anyPerpendicular(normal) }
    }

    /// Moves / rotates the sheet (its sketch rides along); scaling changes the sheet size only.
    public mutating func apply(_ t: TransformParameters) {
        let r = Mat4.rotation(angle: radians(t.rotationDegrees), axis: t.rotationAxis)
        origin = t.matrix.transformPoint(origin)
        let oldRight = right, oldUp = up
        normal = r.transformDirection(normal)
        up = r.transformDirection(up)
        size = Vec2(size.x * simd_length(t.scale * oldRight), size.y * simd_length(t.scale * oldUp))
        orthonormalize()
    }

    // MARK: Guides from other planes

    /// Where another plane crosses this one: the intersection line (local endpoints) and the
    /// points where the other plane's curves pierce this sheet. Used as alignment marks.
    public func guides(from other: SketchPlane) -> (line: (Vec2, Vec2)?, marks: [Vec2]) {
        var line: (Vec2, Vec2)?
        let d = simd_cross(normal, other.normal)
        let dl = simd_length(d)
        if dl > 1e-3 {
            let c = simd_dot(normal, other.normal)
            let h1 = simd_dot(normal, origin), h2 = simd_dot(other.normal, other.origin)
            let a = (h1 - h2 * c) / (1 - c * c), b = (h2 - h1 * c) / (1 - c * c)
            let p = normal * a + other.normal * b
            let reach = simd_length(sheet.max - sheet.min) + simd_distance(p, origin)
            let dir = d / dl
            line = (local(p - dir * reach), local(p + dir * reach))
        }
        var marks: [Vec2] = []
        for path in other.curves where path.anchors.count >= 2 {
            let pts = path.polyline(samplesPerSegment: 24).map { other.world($0) }
            let n = pts.count
            let count = path.closed ? n : n - 1
            guard count > 0 else { continue }
            for i in 0..<count {
                let a = pts[i], b = pts[(i + 1) % n]
                let da = signedDistance(a), db = signedDistance(b)
                if (da <= 0 && db > 0) || (da > 0 && db <= 0) {
                    let t = da / (da - db)
                    marks.append(local(a + (b - a) * t))
                }
            }
        }
        return (line, marks)
    }
}
