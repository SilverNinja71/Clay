import Foundation
import simd

public struct RemeshParameters: Codable, Equatable, Sendable {
    public var voxelSize: Float = 1.2     // mm
    public var smoothing: Int = 2
    public init(voxelSize: Float = 1.2, smoothing: Int = 2) { self.voxelSize = voxelSize; self.smoothing = smoothing }
}

/// Uniform voxel remesh (like Blender's Voxel Remesh): voxelise the closed mesh, then extract a
/// new evenly spaced surface with Naive Surface Nets and relax it with Taubin smoothing.
///
/// Even triangle sizes are what sculpting needs after big Grab/Inflate strokes have stretched
/// the original loft topology.
public enum VoxelRemesher {

    public static func remesh(_ mesh: ClayMesh, parameters: RemeshParameters = .init()) -> ClayMesh? {
        guard !mesh.isEmpty else { return nil }
        var h = max(parameters.voxelSize, 0.2)
        let b = mesh.bounds
        // Keep grids bounded (~220 cells on the longest axis).
        let longest = max(b.size.x, b.size.y, b.size.z)
        if longest / h > 220 { h = longest / 220 }
        let origin = b.min - Vec3(repeating: 2 * h)
        let dims = SIMD3<Int>(Int(ceil((b.size.x + 4 * h) / h)) + 1,
                              Int(ceil((b.size.y + 4 * h) / h)) + 1,
                              Int(ceil((b.size.z + 4 * h) / h)) + 1)
        let nx = dims.x, ny = dims.y, nz = dims.z
        @inline(__always) func gi(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * ny + j) * nx + i }

        // 1. Inside/outside by ray parity along +Z, one ray per (x, y) grid column.
        var field = [Float](repeating: 0, count: nx * ny * nz)
        var buckets = [[Int32]](repeating: [], count: nx * ny)
        let pos = mesh.positions, idx = mesh.indices
        for t in 0..<(idx.count / 3) {
            let a = pos[Int(idx[t * 3])], c1 = pos[Int(idx[t * 3 + 1])], c2 = pos[Int(idx[t * 3 + 2])]
            let lo = simd_min(a, simd_min(c1, c2)), hi = simd_max(a, simd_max(c1, c2))
            let i0 = max(0, Int(floor((lo.x - origin.x) / h))), i1 = min(nx - 1, Int(ceil((hi.x - origin.x) / h)))
            let j0 = max(0, Int(floor((lo.y - origin.y) / h))), j1 = min(ny - 1, Int(ceil((hi.y - origin.y) / h)))
            if i0 > i1 || j0 > j1 { continue }
            for j in j0...j1 { for i in i0...i1 { buckets[j * nx + i].append(Int32(t)) } }
        }
        let jitter = Vec2(0.0137, 0.0071) * h   // avoids rays passing exactly through shared edges
        var hits: [Float] = []
        for j in 0..<ny {
            for i in 0..<nx {
                let bucket = buckets[j * nx + i]
                if bucket.isEmpty { continue }
                let q = Vec2(origin.x + Float(i) * h, origin.y + Float(j) * h) + jitter
                hits.removeAll(keepingCapacity: true)
                for t in bucket {
                    let ti = Int(t) * 3
                    let a = pos[Int(idx[ti])], bb = pos[Int(idx[ti + 1])], c = pos[Int(idx[ti + 2])]
                    let e1 = Vec2(bb.x - a.x, bb.y - a.y), e2 = Vec2(c.x - a.x, c.y - a.y), w = q - Vec2(a.x, a.y)
                    let det = e1.cross(e2)
                    if abs(det) < 1e-12 { continue }
                    let u = w.cross(e2) / det, v = e1.cross(w) / det
                    if u < 0 || v < 0 || u + v > 1 { continue }
                    hits.append(a.z + u * (bb.z - a.z) + v * (c.z - a.z))
                }
                if hits.count < 2 { continue }
                hits.sort()
                var hk = 0
                var inside = false
                for k in 0..<nz {
                    let z = origin.z + Float(k) * h
                    while hk < hits.count && hits[hk] < z { inside.toggle(); hk += 1 }
                    if inside { field[gi(i, j, k)] = 1 }
                }
            }
        }

        // 2. Blur the occupancy once so the iso-surface lands between voxels smoothly.
        field = blur(field, nx, ny, nz)
        let iso: Float = 0.5

        // 3. Naive Surface Nets: one vertex per cell that straddles the surface.
        let cx = nx - 1, cy = ny - 1, cz = nz - 1
        var cellVertex = [Int32](repeating: -1, count: cx * cy * cz)
        @inline(__always) func ci(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * cy + j) * cx + i }
        var verts: [Vec3] = []
        let cornerOffsets: [SIMD3<Int>] = [[0,0,0],[1,0,0],[0,1,0],[1,1,0],[0,0,1],[1,0,1],[0,1,1],[1,1,1]]
        let edges: [(Int, Int)] = [(0,1),(2,3),(4,5),(6,7),(0,2),(1,3),(4,6),(5,7),(0,4),(1,5),(2,6),(3,7)]
        var vals = [Float](repeating: 0, count: 8)
        for k in 0..<cz { for j in 0..<cy { for i in 0..<cx {
            var mask = 0
            for c in 0..<8 {
                let o = cornerOffsets[c]
                vals[c] = field[gi(i + o.x, j + o.y, k + o.z)]
                if vals[c] > iso { mask |= 1 << c }
            }
            if mask == 0 || mask == 255 { continue }
            var acc = Vec3.zero, n: Float = 0
            for (e0, e1) in edges {
                let a = vals[e0], bv = vals[e1]
                if (a > iso) == (bv > iso) { continue }
                let t = (iso - a) / (bv - a)
                let p0 = SIMD3<Float>(cornerOffsets[e0]), p1 = SIMD3<Float>(cornerOffsets[e1])
                acc += p0 + (p1 - p0) * t; n += 1
            }
            let local = acc / n
            cellVertex[ci(i, j, k)] = Int32(verts.count)
            verts.append(origin + (Vec3(Float(i), Float(j), Float(k)) + local) * h)
        }}}

        // 4. A quad for every grid edge with a sign change, joining the 4 cells around it.
        var tris: [UInt32] = []
        for k in 1..<(nz - 1) { for j in 1..<(ny - 1) { for i in 1..<(nx - 1) {
            let inside0 = field[gi(i, j, k)] > iso
            for axis in 0..<3 {
                var e = SIMD3<Int>(0, 0, 0); e[axis] = 1
                let i1 = i + e.x, j1 = j + e.y, k1 = k + e.z
                if i1 >= nx || j1 >= ny || k1 >= nz { continue }
                if inside0 == (field[gi(i1, j1, k1)] > iso) { continue }
                let u = (axis + 1) % 3, v = (axis + 2) % 3
                var du = SIMD3<Int>(0, 0, 0); du[u] = 1
                var dv = SIMD3<Int>(0, 0, 0); dv[v] = 1
                let p = SIMD3<Int>(i, j, k)
                let cells = [p &- du &- dv, p &- dv, p, p &- du]
                var q = [Int32](repeating: -1, count: 4)
                var ok = true
                for (n, c) in cells.enumerated() {
                    if c.x < 0 || c.y < 0 || c.z < 0 || c.x >= cx || c.y >= cy || c.z >= cz { ok = false; break }
                    q[n] = cellVertex[ci(c.x, c.y, c.z)]
                    if q[n] < 0 { ok = false; break }
                }
                if !ok { continue }
                let a = UInt32(q[0]), b1 = UInt32(q[1]), c = UInt32(q[2]), d = UInt32(q[3])
                if inside0 {
                    tris += [a, b1, c, a, c, d]
                } else {
                    tris += [a, c, b1, a, d, c]
                }
            }
        }}}
        guard !tris.isEmpty else { return nil }
        var out = ClayMesh(positions: verts, indices: tris)
        if parameters.smoothing > 0 {
            out.laplacianSmooth(iterations: parameters.smoothing, lambda: 0.5, mu: -0.53)
        }
        return out
    }

    private static func blur(_ f: [Float], _ nx: Int, _ ny: Int, _ nz: Int) -> [Float] {
        var a = f, b = f
        let strides = [1, nx, nx * ny]
        let counts = [nx, ny, nz]
        for axis in 0..<3 {
            let s = strides[axis]
            for idx in 0..<a.count {
                let coord: Int
                switch axis {
                case 0: coord = idx % nx
                case 1: coord = (idx / nx) % ny
                default: coord = idx / (nx * ny)
                }
                let l = coord > 0 ? a[idx - s] : a[idx]
                let r = coord < counts[axis] - 1 ? a[idx + s] : a[idx]
                b[idx] = 0.25 * l + 0.5 * a[idx] + 0.25 * r
            }
            swap(&a, &b)
        }
        return a
    }
}
