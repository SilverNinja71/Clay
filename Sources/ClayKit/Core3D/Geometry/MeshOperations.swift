import Foundation
import simd

// MARK: - Parameters

public struct EdgeTreatment: Codable, Equatable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable { case chamfer, fillet }
    public enum Edge: String, Codable, CaseIterable, Sendable { case bottom, top, both }
    public var style: Style
    public var edge: Edge
    public var size: Float
    public init(style: Style, edge: Edge, size: Float) { self.style = style; self.edge = edge; self.size = size }
}

public struct ShellParameters: Codable, Equatable, Sendable {
    public var thickness: Float = 3
    public var openTop = true
    public init(thickness: Float = 3, openTop: Bool = true) { self.thickness = thickness; self.openTop = openTop }
}

public struct SplitParameters: Codable, Equatable, Sendable {
    public var height: Float
    public var keepBelow = true
    public init(height: Float, keepBelow: Bool = true) { self.height = height; self.keepBelow = keepBelow }
}

public struct TransformParameters: Codable, Equatable, Sendable {
    public var translation: Vec3 = .zero
    public var rotationAxis: Vec3 = Vec3(0, 1, 0)
    public var rotationDegrees: Float = 0
    public var scale: Vec3 = Vec3(repeating: 1)
    public var pivot: Vec3 = .zero
    public init() {}

    public var matrix: Mat4 {
        Mat4.translation(pivot + translation) * Mat4.rotation(angle: radians(rotationDegrees), axis: rotationAxis)
            * Mat4.scale(scale) * Mat4.translation(-pivot)
    }
    public var isIdentity: Bool { translation == .zero && rotationDegrees == 0 && scale == Vec3(repeating: 1) }
}

// MARK: - Operations

/// Mesh-level CAD operations used by timeline features. All of them keep closed meshes closed.
public enum MeshOperations {

    /// Moves every vertex along its normal (positive grows the body).
    public static func offset(_ mesh: ClayMesh, distance: Float) -> ClayMesh {
        var m = mesh
        for i in m.positions.indices { m.positions[i] += m.normals[i] * distance }
        m.recomputeNormals()
        return m
    }

    /// Hollows the body. With `openTop`, the flat top face is removed and the rim bridged to the
    /// inner wall — a vase or cup. Otherwise an inner cavity shell is added (for 3D printing).
    public static func shell(_ mesh: ClayMesh, parameters p: ShellParameters) -> ClayMesh {
        let t = max(p.thickness, 0.05)
        var keep: [UInt32] = []
        if p.openTop {
            let top = mesh.bounds.max.y
            let tol = max(mesh.bounds.size.y * 0.004, 0.05)
            for i in stride(from: 0, to: mesh.indices.count, by: 3) {
                let a = mesh.positions[Int(mesh.indices[i])], b = mesh.positions[Int(mesh.indices[i + 1])], c = mesh.positions[Int(mesh.indices[i + 2])]
                let n = simd_cross(b - a, c - a).safeNormalized
                let isTop = n.y > 0.97 && a.y > top - tol && b.y > top - tol && c.y > top - tol
                if !isTop { keep += mesh.indices[i..<(i + 3)] }
            }
        } else {
            keep = mesh.indices
        }
        var outer = ClayMesh(positions: mesh.positions, indices: keep)
        outer.recomputeNormals()

        let n = UInt32(outer.positions.count)
        var positions = outer.positions
        positions += outer.positions.enumerated().map { $0.element - outer.normals[$0.offset] * t }
        var indices = keep
        for i in stride(from: 0, to: keep.count, by: 3) {
            indices += [keep[i] + n, keep[i + 2] + n, keep[i + 1] + n]
        }
        if p.openTop && keep.count != mesh.indices.count {
            // Bridge each open boundary edge (a→b) to its inner copy.
            var directed = Set<UInt64>()
            for i in stride(from: 0, to: keep.count, by: 3) {
                for k in 0..<3 { directed.insert((UInt64(keep[i + k]) << 32) | UInt64(keep[i + (k + 1) % 3])) }
            }
            for e in directed {
                let a = UInt32(e >> 32), b = UInt32(e & 0xFFFF_FFFF)
                if directed.contains((UInt64(b) << 32) | UInt64(a)) { continue }
                indices += [b, a, a + n, b, a + n, b + n]
            }
        }
        return ClayMesh(positions: positions, indices: indices).compacted()
    }

    /// Cuts the body with the plane y = height and caps the opening, keeping one side.
    public static func split(_ mesh: ClayMesh, parameters p: SplitParameters) -> ClayMesh {
        let sign: Float = p.keepBelow ? 1 : -1
        let d = mesh.positions.map { ($0.y - p.height) * sign }
        var positions = mesh.positions
        var edgeVertex = [UInt64: UInt32]()
        func cut(_ a: UInt32, _ b: UInt32) -> UInt32 {
            let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
            if let v = edgeVertex[key] { return v }
            let da = d[Int(a)], db = d[Int(b)]
            let t = da / (da - db)
            let pa = mesh.positions[Int(a)], pb = mesh.positions[Int(b)]
            var q = pa + (pb - pa) * t
            q.y = p.height
            positions.append(q)
            let v = UInt32(positions.count - 1)
            edgeVertex[key] = v
            return v
        }
        var out: [UInt32] = []
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let tri = [mesh.indices[i], mesh.indices[i + 1], mesh.indices[i + 2]]
            let inside = tri.map { d[Int($0)] <= 0 }
            let count = inside.filter { $0 }.count
            if count == 3 { out += tri; continue }
            if count == 0 { continue }
            // Rotate so the odd vertex is first, keeping winding.
            var r = 0
            for k in 0..<3 where (count == 1 && inside[k]) || (count == 2 && !inside[k]) { r = k }
            let a = tri[r], b = tri[(r + 1) % 3], c = tri[(r + 2) % 3]
            let ab = cut(a, b), ac = cut(a, c)
            if count == 1 {
                out += [a, ab, ac]
            } else {
                out += [ab, b, c, ab, c, ac]
            }
        }
        // Cap: fan every boundary loop to its centroid.
        var next = [UInt32: UInt32]()
        var directed = Set<UInt64>()
        for i in stride(from: 0, to: out.count, by: 3) {
            for k in 0..<3 { directed.insert((UInt64(out[i + k]) << 32) | UInt64(out[i + (k + 1) % 3])) }
        }
        for e in directed {
            let a = UInt32(e >> 32), b = UInt32(e & 0xFFFF_FFFF)
            if !directed.contains((UInt64(b) << 32) | UInt64(a)) { next[a] = b }
        }
        var visited = Set<UInt32>()
        for start in next.keys where !visited.contains(start) {
            var loop: [UInt32] = []
            var cur = start
            while !visited.contains(cur), let nx = next[cur] {
                visited.insert(cur); loop.append(cur); cur = nx
            }
            guard loop.count >= 3 else { continue }
            let centroid = loop.reduce(Vec3.zero) { $0 + positions[Int($1)] } / Float(loop.count)
            positions.append(centroid)
            let cIdx = UInt32(positions.count - 1)
            for (k, a) in loop.enumerated() {
                let b = loop[(k + 1) % loop.count]
                out += [cIdx, b, a]
            }
        }
        return ClayMesh(positions: positions, indices: out).compacted()
    }

    /// Chamfers or fillets the outer edge of the bottom/top faces by shrinking the silhouette
    /// radially (about the vertical axis) within `size` of the end plane.
    public static func edgeTreatment(_ mesh: ClayMesh, _ e: EdgeTreatment) -> ClayMesh {
        var m = mesh
        let b = mesh.bounds
        let c = b.center.xz
        let size = min(max(e.size, 0.01), b.size.y * 0.45)
        func profile(_ dy: Float) -> Float {
            guard dy < size else { return 0 }
            switch e.style {
            case .chamfer: return size - dy
            case .fillet:
                let k = size - dy
                return size - sqrt(max(0, size * size - k * k))
            }
        }
        func endRadius(_ y: Float) -> Float {
            var r: Float = 0
            for p in mesh.positions where abs(p.y - y) < size * 0.05 + 0.05 { r = max(r, simd_distance(p.xz, c)) }
            return max(r, 0.01)
        }
        let rBottom = endRadius(b.min.y), rTop = endRadius(b.max.y)
        for i in m.positions.indices {
            var p = m.positions[i]
            var off: Float = 0, rEnd: Float = 1
            if e.edge != .top { let o = profile(p.y - b.min.y); if o > off { off = o; rEnd = rBottom } }
            if e.edge != .bottom { let o = profile(b.max.y - p.y); if o > off { off = o; rEnd = rTop } }
            guard off > 0 else { continue }
            let v = p.xz - c
            let r = simd_length(v)
            guard r > 1e-5 else { continue }
            let shrink = off * min(1, r / rEnd)
            let nr = max(r - shrink, 0)
            let nv = v / r * nr
            p.x = c.x + nv.x; p.z = c.y + nv.y
            m.positions[i] = p
        }
        m.recomputeNormals()
        return m
    }

    /// 1→4 midpoint subdivision (shape-preserving; adds density for sculpting).
    public static func subdivide(_ mesh: ClayMesh) -> ClayMesh {
        var positions = mesh.positions
        var mid = [UInt64: UInt32]()
        func m(_ a: UInt32, _ b: UInt32) -> UInt32 {
            let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
            if let v = mid[key] { return v }
            positions.append((mesh.positions[Int(a)] + mesh.positions[Int(b)]) * 0.5)
            let v = UInt32(positions.count - 1)
            mid[key] = v
            return v
        }
        var out: [UInt32] = []
        out.reserveCapacity(mesh.indices.count * 4)
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.indices[i], b = mesh.indices[i + 1], c = mesh.indices[i + 2]
            let ab = m(a, b), bc = m(b, c), ca = m(c, a)
            out += [a, ab, ca, ab, b, bc, ca, bc, c, ab, bc, ca]
        }
        var r = ClayMesh(positions: positions, indices: out)
        r.laplacianSmooth(iterations: 1, lambda: 0.3, mu: -0.31)
        return r
    }

    public static func transform(_ mesh: ClayMesh, _ t: TransformParameters) -> ClayMesh {
        var m = mesh
        m.apply(t.matrix)
        return m
    }
}
