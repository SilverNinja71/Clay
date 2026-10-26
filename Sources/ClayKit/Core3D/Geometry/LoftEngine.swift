import Foundation
import simd

// MARK: - Silhouette profile

/// A sketch reduced to "how wide is the shape at height v?".
///
/// Closed loops are used as drawn. Open strokes are treated as half-profiles and mirrored
/// about the centre axis (u = 0) — draw one side of a vase and you get the whole silhouette.
public struct SilhouetteProfile: Sendable {
    public private(set) var polygons: [[Vec2]]
    public let vRange: ClosedRange<Float>

    public init?(sketch: Sketch, samplesPerSegment: Int = 32) {
        var polys: [[Vec2]] = []
        for path in sketch.paths where path.anchors.count >= 2 {
            var pts = path.polyline(samplesPerSegment: samplesPerSegment)
            if !path.closed {
                let side: Float = pts.reduce(0) { $0 + $1.x } >= 0 ? 1 : -1
                pts = pts.map { Vec2(abs($0.x) * side, $0.y) }
                let mirrored = pts.reversed().map { Vec2(-$0.x, $0.y) }
                pts += mirrored
            }
            if pts.count >= 3 { polys.append(pts) }
        }
        guard !polys.isEmpty else { return nil }
        var lo = Float.greatestFiniteMagnitude, hi = -lo
        for p in polys.joined() { lo = min(lo, p.y); hi = max(hi, p.y) }
        guard hi - lo > 0.5 else { return nil }
        polygons = polys
        vRange = lo...hi
    }

    public var height: Float { vRange.upperBound - vRange.lowerBound }

    /// Horizontal extent (min u, max u) where the line v = `v` crosses the silhouette.
    public func extent(at v: Float) -> ClosedRange<Float>? {
        var lo = Float.greatestFiniteMagnitude, hi = -lo
        for poly in polygons {
            let n = poly.count
            for i in 0..<n {
                let a = poly[i], b = poly[(i + 1) % n]
                if (a.y <= v && b.y >= v) || (b.y <= v && a.y >= v) {
                    let dy = b.y - a.y
                    let u = abs(dy) < 1e-7 ? min(a.x, b.x) : a.x + (v - a.y) / dy * (b.x - a.x)
                    let u2 = abs(dy) < 1e-7 ? max(a.x, b.x) : u
                    lo = min(lo, u, u2); hi = max(hi, u, u2)
                }
            }
        }
        return lo <= hi ? lo...hi : nil
    }

    public var maxWidth: (width: Float, at: Float) {
        var best: (Float, Float) = (0, vRange.lowerBound)
        for i in 0...200 {
            let v = vRange.lowerBound + height * Float(i) / 200
            if let e = extent(at: v), e.upperBound - e.lowerBound > best.0 { best = (e.upperBound - e.lowerBound, v) }
        }
        return best
    }
}

// MARK: - Loft

public struct LoftParameters: Codable, Equatable, Sendable {
    public var frontSketch: UUID
    public var sideSketch: UUID?
    /// Horizontal rings from bottom to top (changing it changes topology, invalidating sculpt layers).
    public var rings: Int = 150
    public var segments: Int = 128
    /// 0 = elliptical cross-sections, 1 = nearly square (superellipse exponent 2 → 10).
    public var squareness: Float = 0
    public var capped: Bool = true

    public init(frontSketch: UUID, sideSketch: UUID?) {
        self.frontSketch = frontSketch; self.sideSketch = sideSketch
    }
}

/// Dual-silhouette cross-lofting.
///
/// For each height v the front silhouette gives the X extent [x0, x1] and the side silhouette
/// gives the Z extent. A superellipse through those four extremes is the cross-section; stacking
/// the sections and capping both ends gives a closed, manifold triangle mesh.
public enum LoftEngine {

    public enum LoftError: Error, LocalizedError {
        case missingFront, tooSmall
        public var errorDescription: String? {
            switch self {
            case .missingFront: "Draw a front silhouette first."
            case .tooSmall: "The sketch is too small to loft."
            }
        }
    }

    public static func loft(front: Sketch, side: Sketch?, parameters p: LoftParameters) throws -> ClayMesh {
        guard let fp = SilhouetteProfile(sketch: front) else { throw LoftError.missingFront }
        let sp = side.flatMap { SilhouetteProfile(sketch: $0) }

        // Height range: the front silhouette drives height; the side is mapped onto it when the
        // two disagree badly (otherwise absolute alignment is kept, like matching orthographic views).
        let v0 = fp.vRange.lowerBound, v1 = fp.vRange.upperBound
        guard v1 - v0 > 1 else { throw LoftError.tooSmall }
        var sideMap: (Float) -> Float = { $0 }
        if let sp {
            let overlap = min(v1, sp.vRange.upperBound) - max(v0, sp.vRange.lowerBound)
            if overlap < 0.9 * (v1 - v0) {
                sideMap = { v in sp.vRange.lowerBound + (v - v0) / (v1 - v0) * sp.height }
            }
        }

        let rings = max(3, p.rings), segs = max(8, p.segments)
        let exponent = 2 + clamp(p.squareness, 0, 1) * 8
        let eps: Float = 0.0015

        // Cosine spacing puts more rings near the top and bottom, where curvature is highest.
        var sections: [(cx: Float, a: Float, cz: Float, b: Float, y: Float)] = []
        var last: (Float, Float, Float, Float)?
        for i in 0..<rings {
            let t = eps + (1 - 2 * eps) * Float(i) / Float(rings - 1)
            let s = (1 - cos(.pi * t)) * 0.5
            let y = v0 + (v1 - v0) * s
            let fx = fp.extent(at: y)
            let sz = sp?.extent(at: sideMap(y))
            var cx: Float, a: Float, cz: Float, b: Float
            if let fx {
                cx = (fx.lowerBound + fx.upperBound) / 2; a = (fx.upperBound - fx.lowerBound) / 2
            } else if let l = last { cx = l.0; a = l.1 } else { cx = 0; a = 0.01 }
            if let sz {
                // Side plane u maps to world −Z.
                cz = -(sz.lowerBound + sz.upperBound) / 2; b = (sz.upperBound - sz.lowerBound) / 2
            } else if sp == nil {
                cz = 0; b = a            // no side sketch: round cross-sections (a revolve)
            } else if let l = last { cz = l.2; b = l.3 } else { cz = 0; b = a }
            a = max(a, 0.01); b = max(b, 0.01)
            last = (cx, a, cz, b)
            sections.append((cx, a, cz, b, y))
        }

        var positions: [Vec3] = []
        positions.reserveCapacity(rings * segs + 2)
        // Precompute the superellipse unit shape.
        var unit: [Vec2] = []
        for j in 0..<segs {
            let th = 2 * Float.pi * Float(j) / Float(segs)
            let c = cos(th), s = sin(th)
            let e = 2 / exponent
            unit.append(Vec2(copysign(pow(abs(c), e), c), copysign(pow(abs(s), e), s)))
        }
        for sec in sections {
            for u in unit {
                positions.append(Vec3(sec.cx + sec.a * u.x, sec.y, sec.cz + sec.b * u.y))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity((rings - 1) * segs * 6 + segs * 6)
        func vid(_ i: Int, _ j: Int) -> UInt32 { UInt32(i * segs + (j % segs)) }
        for i in 0..<(rings - 1) {
            for j in 0..<segs {
                let a = vid(i, j), b = vid(i + 1, j), c = vid(i, j + 1), d = vid(i + 1, j + 1)
                indices += [a, b, c, c, b, d]
            }
        }
        if p.capped {
            let bottom = UInt32(positions.count)
            let s0 = sections[0]
            positions.append(Vec3(s0.cx, s0.y, s0.cz))
            let top = UInt32(positions.count)
            let s1 = sections[rings - 1]
            positions.append(Vec3(s1.cx, s1.y, s1.cz))
            for j in 0..<segs {
                indices += [bottom, vid(0, j), vid(0, j + 1)]
                indices += [top, vid(rings - 1, j + 1), vid(rings - 1, j)]
            }
        }
        return ClayMesh(positions: positions, indices: indices)
    }
}

// MARK: - Extrude

public struct ExtrudeParameters: Codable, Equatable, Sendable {
    public var sketch: UUID
    public var depth: Float
    public var symmetric: Bool = true
    /// Only these paths (nil = every closed path in the sketch).
    public var paths: [UUID]?
    public init(sketch: UUID, depth: Float, paths: [UUID]? = nil) { self.sketch = sketch; self.depth = depth; self.paths = paths }
}

/// Linear extrusion of closed sketch loops along the plane normal (a prism, capped with ear clipping).
public enum ExtrudeEngine {
    public static func extrude(sketch: Sketch, plane: SketchPlane, parameters p: ExtrudeParameters) -> ClayMesh? {
        var mesh = ClayMesh.empty
        for path in sketch.paths where path.closed && path.anchors.count >= 2 && (p.paths?.contains(path.id) ?? true) {
            var poly = path.polyline(samplesPerSegment: 16)
            if signedArea(poly) < 0 { poly.reverse() }
            guard poly.count >= 3, let tris = earClip(poly) else { continue }
            let d0: Float = p.symmetric ? -p.depth / 2 : 0
            let d1: Float = p.symmetric ? p.depth / 2 : p.depth
            let n = poly.count
            var pos: [Vec3] = []
            for q in poly { pos.append(plane.worldPoint(q, offset: d1)) }
            for q in poly { pos.append(plane.worldPoint(q, offset: d0)) }
            // Planes are right-handed with normal toward the viewer, so CCW loops face +normal.
            var idx: [UInt32] = []
            for t in tris { idx += [UInt32(t.0), UInt32(t.1), UInt32(t.2)] }                  // front cap
            for t in tris { idx += [UInt32(t.0 + n), UInt32(t.2 + n), UInt32(t.1 + n)] }      // back cap
            for i in 0..<n {
                let a = UInt32(i), b = UInt32((i + 1) % n)
                idx += [a, a + UInt32(n), b, b, a + UInt32(n), b + UInt32(n)]
            }
            var body = ClayMesh(positions: pos, indices: idx)
            if body.volume < 0 {
                for t in stride(from: 0, to: body.indices.count, by: 3) { body.indices.swapAt(t + 1, t + 2) }
                body.invalidateTopology()
                body.recomputeNormals()
            }
            mesh.append(body)
        }
        if mesh.isEmpty { return nil }
        mesh.recomputeNormals()
        return mesh
    }

    public static func signedArea(_ poly: [Vec2]) -> Float {
        var a: Float = 0
        for i in poly.indices { a += poly[i].cross(poly[(i + 1) % poly.count]) }
        return a / 2
    }

    /// Ear-clipping triangulation of a simple CCW polygon.
    public static func earClip(_ poly: [Vec2]) -> [(Int, Int, Int)]? {
        var idx = Array(poly.indices)
        var out: [(Int, Int, Int)] = []
        var guardCount = 0
        while idx.count > 3 && guardCount < poly.count * poly.count {
            guardCount += 1
            var clipped = false
            for k in 0..<idx.count {
                let i0 = idx[(k - 1 + idx.count) % idx.count], i1 = idx[k], i2 = idx[(k + 1) % idx.count]
                let a = poly[i0], b = poly[i1], c = poly[i2]
                if (b - a).cross(c - b) <= 1e-9 { continue } // reflex or degenerate
                var contains = false
                for j in idx where j != i0 && j != i1 && j != i2 {
                    if pointInTriangle(poly[j], a, b, c) { contains = true; break }
                }
                if contains { continue }
                out.append((i0, i1, i2))
                idx.remove(at: k)
                clipped = true
                break
            }
            if !clipped { idx.remove(at: 0) } // self-intersecting input: drop a vertex and continue
        }
        if idx.count == 3 { out.append((idx[0], idx[1], idx[2])) }
        return out.isEmpty ? nil : out
    }

    static func pointInTriangle(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
        let d1 = (b - a).cross(p - a), d2 = (c - b).cross(p - b), d3 = (a - c).cross(p - c)
        return d1 >= 0 && d2 >= 0 && d3 >= 0
    }
}
