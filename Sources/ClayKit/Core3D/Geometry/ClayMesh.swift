import Foundation
import simd

/// Indexed triangle mesh. Positions/normals are SIMD3<Float> (16-byte stride), which matches
/// Metal's `float3`, so the arrays upload to the GPU without conversion.
public struct ClayMesh: Sendable {
    public var positions: [Vec3]
    public var normals: [Vec3]
    public var indices: [UInt32]
    /// Changes whenever geometry changes; the renderer re-uploads when it differs.
    public var revision: UInt64
    /// Changes only when the triangle list changes (wireframe edges are rebuilt then).
    public private(set) var topologyRevision: UInt64
    /// Adjacency is derived from `indices` only, so it can be shared between copies.
    private var topologyBox: TopologyBox

    public init(positions: [Vec3], indices: [UInt32], normals: [Vec3]? = nil) {
        self.positions = positions
        self.indices = indices
        self.normals = normals ?? []
        self.revision = Revision.next()
        self.topologyRevision = revision
        self.topologyBox = TopologyBox()
        if normals == nil { recomputeNormals() }
    }

    public static let empty = ClayMesh(positions: [], indices: [], normals: [])

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { indices.count / 3 }
    public var isEmpty: Bool { indices.isEmpty }
    public var bounds: AABB { AABB(points: positions) }

    public mutating func touch() { revision = Revision.next() }

    // MARK: Topology

    public final class Topology: @unchecked Sendable {
        /// One-ring vertex neighbours.
        public let neighbors: [[Int32]]
        /// Triangles incident to each vertex.
        public let vertexTriangles: [[Int32]]
        init(mesh: ClayMesh) {
            var nb = [[Int32]](repeating: [], count: mesh.vertexCount)
            var vt = [[Int32]](repeating: [], count: mesh.vertexCount)
            let idx = mesh.indices
            for t in 0..<(idx.count / 3) {
                let a = Int(idx[t * 3]), b = Int(idx[t * 3 + 1]), c = Int(idx[t * 3 + 2])
                vt[a].append(Int32(t)); vt[b].append(Int32(t)); vt[c].append(Int32(t))
                nb[a].append(Int32(b)); nb[a].append(Int32(c))
                nb[b].append(Int32(a)); nb[b].append(Int32(c))
                nb[c].append(Int32(a)); nb[c].append(Int32(b))
            }
            for i in nb.indices { nb[i] = Array(Set(nb[i])) }
            neighbors = nb
            vertexTriangles = vt
        }
    }

    private final class TopologyBox: @unchecked Sendable {
        var topology: Topology?
        var indexCount = -1
    }

    /// Lazily built adjacency (rebuilt automatically if the index buffer changed size).
    public var topology: Topology {
        if let t = topologyBox.topology, topologyBox.indexCount == indices.count { return t }
        let t = Topology(mesh: self)
        topologyBox.topology = t
        topologyBox.indexCount = indices.count
        return t
    }

    /// Call after replacing `indices` in place.
    public mutating func invalidateTopology() {
        topologyBox = TopologyBox()
        topologyRevision = Revision.next()
    }

    // MARK: Normals

    public mutating func recomputeNormals() {
        var n = [Vec3](repeating: .zero, count: positions.count)
        positions.withUnsafeBufferPointer { p in
            indices.withUnsafeBufferPointer { idx in
                for t in stride(from: 0, to: idx.count, by: 3) {
                    let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
                    let fn = simd_cross(p[b] - p[a], p[c] - p[a]) // area-weighted
                    n[a] += fn; n[b] += fn; n[c] += fn
                }
            }
        }
        for i in n.indices { n[i] = n[i].safeNormalized }
        normals = n
        touch()
    }

    /// Recomputes normals only around the given vertices (used while sculpting).
    public mutating func recomputeNormals(around verts: [Int]) {
        let topo = topology
        var tris = Set<Int32>()
        var touched = Set<Int>()
        for v in verts {
            for t in topo.vertexTriangles[v] {
                tris.insert(t)
            }
        }
        for t in tris {
            let i = Int(t) * 3
            touched.insert(Int(indices[i])); touched.insert(Int(indices[i + 1])); touched.insert(Int(indices[i + 2]))
        }
        for v in touched {
            var acc = Vec3.zero
            for t in topo.vertexTriangles[v] {
                let i = Int(t) * 3
                let a = positions[Int(indices[i])], b = positions[Int(indices[i + 1])], c = positions[Int(indices[i + 2])]
                acc += simd_cross(b - a, c - a)
            }
            normals[v] = acc.safeNormalized
        }
        touch()
    }

    // MARK: Queries

    public struct Hit: Sendable {
        public var position: Vec3
        public var normal: Vec3
        public var distance: Float
        public var triangle: Int
    }

    /// Brute-force closest hit with a bounding-sphere early-out (fast enough for ~100k triangles).
    public func raycast(_ ray: Ray) -> Hit? {
        guard !indices.isEmpty else { return nil }
        let b = bounds
        let oc = ray.origin - b.center
        let proj = simd_dot(oc, ray.direction)
        if simd_length_squared(oc) - proj * proj > b.radius * b.radius * 1.01 { return nil }
        var bestT = Float.greatestFiniteMagnitude
        var bestTri = -1
        positions.withUnsafeBufferPointer { p in
            indices.withUnsafeBufferPointer { idx in
                let o = ray.origin, d = ray.direction
                for t in stride(from: 0, to: idx.count, by: 3) {
                    if let hit = rayTriangle(o, d, p[Int(idx[t])], p[Int(idx[t + 1])], p[Int(idx[t + 2])]), hit < bestT {
                        bestT = hit; bestTri = t / 3
                    }
                }
            }
        }
        guard bestTri >= 0 else { return nil }
        let i = bestTri * 3
        let a = positions[Int(indices[i])], bb = positions[Int(indices[i + 1])], c = positions[Int(indices[i + 2])]
        var n = simd_cross(bb - a, c - a).safeNormalized
        if simd_dot(n, ray.direction) > 0 { n = -n }
        return Hit(position: ray.at(bestT), normal: n, distance: bestT, triangle: bestTri)
    }

    /// Every edge must be shared by exactly two triangles with opposite orientation.
    public var isWatertight: Bool {
        guard !indices.isEmpty else { return false }
        var edges = [UInt64: Int]()
        edges.reserveCapacity(indices.count)
        for t in stride(from: 0, to: indices.count, by: 3) {
            for k in 0..<3 {
                let a = UInt64(indices[t + k]), b = UInt64(indices[t + (k + 1) % 3])
                edges[(a << 32) | b, default: 0] += 1
            }
        }
        for (key, count) in edges {
            let a = key >> 32, b = key & 0xFFFF_FFFF
            if count != 1 || edges[(b << 32) | a] != 1 { return false }
        }
        return true
    }

    /// Signed volume (mm³) from the divergence theorem; positive for outward-facing meshes.
    public var volume: Float {
        var v: Double = 0
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = positions[Int(indices[t])], b = positions[Int(indices[t + 1])], c = positions[Int(indices[t + 2])]
            v += Double(simd_dot(a, simd_cross(b, c)))
        }
        return Float(v / 6)
    }

    public var surfaceArea: Float {
        var s: Float = 0
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = positions[Int(indices[t])], b = positions[Int(indices[t + 1])], c = positions[Int(indices[t + 2])]
            s += simd_length(simd_cross(b - a, c - a)) * 0.5
        }
        return s
    }

    /// Unique undirected edges, for the wireframe overlay.
    public func edgeIndices() -> [UInt32] {
        var seen = Set<UInt64>()
        seen.reserveCapacity(indices.count)
        var out: [UInt32] = []
        out.reserveCapacity(indices.count)
        for t in stride(from: 0, to: indices.count, by: 3) {
            for k in 0..<3 {
                let a = indices[t + k], b = indices[t + (k + 1) % 3]
                let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
                if seen.insert(key).inserted { out.append(a); out.append(b) }
            }
        }
        return out
    }

    /// Width (X) of the mesh measured in a thin horizontal slab at height `y`.
    public func extent(atHeight y: Float, band: Float) -> (x: ClosedRange<Float>, z: ClosedRange<Float>)? {
        var lo = Vec2(repeating: .greatestFiniteMagnitude), hi = -lo
        var found = false
        for p in positions where abs(p.y - y) <= band {
            lo = simd_min(lo, p.xz); hi = simd_max(hi, p.xz); found = true
        }
        return found ? (lo.x...hi.x, lo.y...hi.y) : nil
    }

    // MARK: Basic edits

    public mutating func apply(_ m: Mat4) {
        let nm = m.normalMatrix
        for i in positions.indices {
            positions[i] = m.transformPoint(positions[i])
            normals[i] = (nm * normals[i]).safeNormalized
        }
        if simd_determinant(nm) < 0 {
            // Mirroring flips winding; restore outward orientation.
            for t in stride(from: 0, to: indices.count, by: 3) { indices.swapAt(t + 1, t + 2) }
            invalidateTopology()
        }
        touch()
    }

    /// Drops vertices that no triangle references (after cuts or face removal).
    public func compacted() -> ClayMesh {
        var remap = [Int32](repeating: -1, count: positions.count)
        var newPositions: [Vec3] = []
        newPositions.reserveCapacity(positions.count)
        var newIndices = indices
        for (k, i) in indices.enumerated() {
            if remap[Int(i)] < 0 {
                remap[Int(i)] = Int32(newPositions.count)
                newPositions.append(positions[Int(i)])
            }
            newIndices[k] = UInt32(remap[Int(i)])
        }
        if newPositions.count == positions.count { return self }
        return ClayMesh(positions: newPositions, indices: newIndices)
    }

    /// Concatenates another mesh (bodies stay separate shells).
    public mutating func append(_ other: ClayMesh) {
        let base = UInt32(positions.count)
        positions += other.positions
        normals += other.normals
        indices += other.indices.map { $0 + base }
        invalidateTopology()
        touch()
    }

    /// Laplacian smoothing of the whole mesh (`lambda` > 0 smooths, Taubin uses a negative pass).
    public mutating func laplacianSmooth(iterations: Int, lambda: Float, mu: Float? = nil) {
        let nb = topology.neighbors
        for _ in 0..<iterations {
            for factor in [lambda, mu].compactMap({ $0 }) {
                var next = positions
                for i in positions.indices where !nb[i].isEmpty {
                    var avg = Vec3.zero
                    for j in nb[i] { avg += positions[Int(j)] }
                    avg /= Float(nb[i].count)
                    next[i] = positions[i] + (avg - positions[i]) * factor
                }
                positions = next
            }
        }
        recomputeNormals()
    }
}
