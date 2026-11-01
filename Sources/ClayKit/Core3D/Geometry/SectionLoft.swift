import Foundation
import simd

public struct SectionLoftParameters: Codable, Equatable, Sendable {
    /// Sketch planes (their feature ids) whose closed curves are the cross-sections.
    public var planes: [UUID]
    /// Points around every section.
    public var samples: Int = 160
    /// Rings generated between two neighbouring sections (smoothness).
    public var spanRings: Int = 16
    /// For a single section: how far it puffs out, relative to its half-size.
    public var inflate: Float = 0.6
    public init(planes: [UUID]) { self.planes = planes }
}

/// Cross-section lofting through curves on any number of positioned sketch planes
/// (parallel, angled or fanned), producing a watertight mesh.
///
/// 1. Each plane contributes its largest closed curve, resampled to `samples` points.
/// 2. Sections are ordered along their average normal.
/// 3. Loops get the same winding and the start points are rotated to line up.
/// 4. Corresponding points are joined with Catmull–Rom splines (smooth, not faceted).
/// 5. Both ends are capped by ear-clipping the end sections.
/// One section on its own is inflated into a rounded "pillow".
public enum SectionLoftEngine {

    public enum LoftError: Error, LocalizedError {
        case noClosedCurves
        public var errorDescription: String? { "Draw a closed shape on at least one sketch plane." }
    }

    struct Section {
        var plane: SketchPlane
        var points: [Vec2]       // plane-local, resampled
    }

    public static func loft(planes: [SketchPlane], parameters p: SectionLoftParameters) throws -> ClayMesh {
        let m = max(12, p.samples)
        var sections: [Section] = []
        for plane in planes {
            let closed = plane.curves.filter { $0.closed && $0.anchors.count >= 2 }
            guard let path = closed.max(by: { abs(ExtrudeEngine.signedArea($0.polyline(samplesPerSegment: 12))) < abs(ExtrudeEngine.signedArea($1.polyline(samplesPerSegment: 12))) }) else { continue }
            let pts = resampleClosed(path.polyline(samplesPerSegment: 32), count: m)
            if pts.count == m { sections.append(Section(plane: plane, points: pts)) }
        }
        guard !sections.isEmpty else { throw LoftError.noClosedCurves }
        if sections.count == 1 { return inflate(sections[0], parameters: p) }

        // Common direction: average of the normals, flipped to agree.
        var axis = sections[0].plane.normal
        for s in sections.dropFirst() { axis += simd_dot(s.plane.normal, axis) < 0 ? -s.plane.normal : s.plane.normal }
        axis = axis.safeNormalized == .zero ? Vec3(0, 0, 1) : axis.safeNormalized
        func centre(_ s: Section) -> Vec3 { s.plane.world(s.points.reduce(.zero, +) / Float(s.points.count)) }
        sections.sort { simd_dot(centre($0), axis) < simd_dot(centre($1), axis) }

        var loops: [[Vec3]] = sections.map { s in s.points.map { s.plane.world($0) } }
        for i in loops.indices where simd_dot(newellNormal(loops[i]), axis) < 0 { loops[i].reverse() }
        for i in 1..<loops.count { loops[i] = align(loops[i], to: loops[i - 1]) }

        // Smooth rings between the sections.
        let span = max(1, p.spanRings)
        let n = loops.count
        var rings: [[Vec3]] = []
        for k in 0..<(n - 1) {
            let l0 = loops[max(k - 1, 0)], l1 = loops[k], l2 = loops[k + 1], l3 = loops[min(k + 2, n - 1)]
            for s in 0..<span {
                let t = Float(s) / Float(span)
                rings.append((0..<m).map { catmullRom(l0[$0], l1[$0], l2[$0], l3[$0], t) })
            }
        }
        rings.append(loops[n - 1])

        var mesh = tube(rings, m: m)
        capEnd(&mesh, ring: 0, m: m, plane: sections[0].plane, outward: -axis)
        capEnd(&mesh, ring: rings.count - 1, m: m, plane: sections[n - 1].plane, outward: axis)
        return finish(mesh)
    }

    // MARK: Single section → pillow

    static func inflate(_ s: Section, parameters p: SectionLoftParameters) -> ClayMesh {
        let m = s.points.count
        let c = s.points.reduce(.zero, +) / Float(m)
        var lo = Vec2(repeating: .greatestFiniteMagnitude), hi = -lo
        for q in s.points { lo = simd_min(lo, q); hi = simd_max(hi, q) }
        let depth = max(0.5, min(hi.x - lo.x, hi.y - lo.y) * 0.5 * max(p.inflate, 0.05))
        var pts2 = s.points
        if ExtrudeEngine.signedArea(pts2) < 0 { pts2.reverse() }   // CCW around the plane normal
        let k = max(4, p.spanRings / 2)
        var rings: [[Vec3]] = []
        for i in -(k - 1)...(k - 1) {
            let theta = Float.pi / 2 * Float(i) / Float(k)
            let scale = cos(theta), offset = depth * sin(theta)
            rings.append(pts2.map { s.plane.world(c + ($0 - c) * scale, offset: offset) })
        }
        var mesh = tube(rings, m: m)
        let bottom = UInt32(mesh.positions.count)
        mesh.positions.append(s.plane.world(c, offset: -depth))
        let top = UInt32(mesh.positions.count)
        mesh.positions.append(s.plane.world(c, offset: depth))
        let last = UInt32((rings.count - 1) * m)
        for j in 0..<m {
            let a = UInt32(j), b = UInt32((j + 1) % m)
            mesh.indices += [bottom, b, a]
            mesh.indices += [top, last + a, last + b]
        }
        return finish(mesh)
    }

    // MARK: Mesh building

    /// Side walls between consecutive rings (each a loop going counter-clockwise around the axis).
    static func tube(_ rings: [[Vec3]], m: Int) -> ClayMesh {
        var mesh = ClayMesh.empty
        mesh.positions = rings.flatMap { $0 }
        var idx: [UInt32] = []
        idx.reserveCapacity((rings.count - 1) * m * 6)
        for r in 0..<(rings.count - 1) {
            for j in 0..<m {
                let a = UInt32(r * m + j), b = UInt32(r * m + (j + 1) % m)
                let c = UInt32((r + 1) * m + j), d = UInt32((r + 1) * m + (j + 1) % m)
                idx += [a, b, c, b, d, c]
            }
        }
        mesh.indices = idx
        return mesh
    }

    /// Ear-clips an end ring in its section plane, facing `outward`.
    static func capEnd(_ mesh: inout ClayMesh, ring: Int, m: Int, plane: SketchPlane, outward: Vec3) {
        let base = ring * m
        let loop2 = (0..<m).map { plane.local(mesh.positions[base + $0]) }
        let ccw = ExtrudeEngine.signedArea(loop2) >= 0
        let order = ccw ? Array(0..<m) : Array((0..<m).reversed())
        guard let tris = ExtrudeEngine.earClip(order.map { loop2[$0] }) else { return }
        // Ear clipping returns counter-clockwise triangles, i.e. facing +plane.normal.
        let flip = simd_dot(plane.normal, outward) < 0
        for t in tris {
            let a = UInt32(base + order[t.0]), b = UInt32(base + order[t.1]), c = UInt32(base + order[t.2])
            mesh.indices += flip ? [a, c, b] : [a, b, c]
        }
    }

    static func finish(_ mesh: ClayMesh) -> ClayMesh {
        var out = ClayMesh(positions: mesh.positions, indices: mesh.indices)
        if out.volume < 0 {
            for t in stride(from: 0, to: out.indices.count, by: 3) { out.indices.swapAt(t + 1, t + 2) }
            out.invalidateTopology()
            out.recomputeNormals()
        }
        return out
    }

    // MARK: Helpers

    /// Evenly spaced points (by arc length) around a closed polyline.
    static func resampleClosed(_ poly: [Vec2], count: Int) -> [Vec2] {
        guard poly.count >= 3 else { return [] }
        var cum: [Float] = [0]
        for i in 0..<poly.count { cum.append(cum[cum.count - 1] + simd_distance(poly[i], poly[(i + 1) % poly.count])) }
        let total = cum[cum.count - 1]
        guard total > 1e-4 else { return [] }
        var out: [Vec2] = []
        var seg = 0
        for k in 0..<count {
            let target = total * Float(k) / Float(count)
            while seg < poly.count - 1 && cum[seg + 1] < target { seg += 1 }
            let a = poly[seg], b = poly[(seg + 1) % poly.count]
            let len = cum[seg + 1] - cum[seg]
            out.append(len > 1e-6 ? a + (b - a) * ((target - cum[seg]) / len) : a)
        }
        return out
    }

    /// Area-weighted normal of a 3D loop (Newell's method); its direction gives the winding.
    static func newellNormal(_ loop: [Vec3]) -> Vec3 {
        var n = Vec3.zero
        for i in loop.indices {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            let x: Float = (a.y - b.y) * (a.z + b.z)
            let y: Float = (a.z - b.z) * (a.x + b.x)
            let z: Float = (a.x - b.x) * (a.y + b.y)
            n += Vec3(x, y, z)
        }
        return n
    }

    /// Rotates `loop` so its points line up best with `ref` (no twisting between sections).
    static func align(_ loop: [Vec3], to ref: [Vec3]) -> [Vec3] {
        let m = loop.count
        let c = loop.reduce(.zero, +) / Float(m), rc = ref.reduce(.zero, +) / Float(m)
        var best = 0, bestCost = Float.greatestFiniteMagnitude
        for r in 0..<m {
            var cost: Float = 0
            for j in stride(from: 0, to: m, by: 2) {
                cost += simd_distance_squared(loop[(j + r) % m] - c, ref[j] - rc)
                if cost >= bestCost { break }
            }
            if cost < bestCost { bestCost = cost; best = r }
        }
        return (0..<m).map { loop[($0 + best) % m] }
    }

    static func catmullRom(_ p0: Vec3, _ p1: Vec3, _ p2: Vec3, _ p3: Vec3, _ t: Float) -> Vec3 {
        let t2: Float = t * t, t3: Float = t2 * t
        let a: Vec3 = p1 * 2
        let b: Vec3 = (p2 - p0) * t
        var c: Vec3 = p0 * 2
        c -= p1 * 5
        c += p2 * 4
        c -= p3
        var d: Vec3 = p1 * 3
        d -= p0
        d -= p2 * 3
        d += p3
        let sum: Vec3 = a + b + c * t2 + d * t3
        return sum * 0.5
    }
}
