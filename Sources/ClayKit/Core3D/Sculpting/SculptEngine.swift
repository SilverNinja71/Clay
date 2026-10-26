import Foundation
import simd

/// Uniform spatial hash over vertex positions for fast "which vertices are inside the brush?" queries.
struct SpatialHash {
    private(set) var cellSize: Float
    private var order: [Int32] = []
    private var ranges: [Int64: Range<Int>] = [:]

    init(positions: [Vec3], cellSize: Float) {
        self.cellSize = max(cellSize, 0.25)
        rebuild(positions)
    }

    @inline(__always) private func key(_ p: Vec3) -> Int64 { key(cell(p)) }
    @inline(__always) private func cell(_ p: Vec3) -> SIMD3<Int32> {
        SIMD3<Int32>(Int32(floor(p.x / cellSize)), Int32(floor(p.y / cellSize)), Int32(floor(p.z / cellSize)))
    }
    @inline(__always) private func key(_ c: SIMD3<Int32>) -> Int64 {
        (Int64(c.x & 0x1FFFFF) << 42) | (Int64(c.y & 0x1FFFFF) << 21) | Int64(c.z & 0x1FFFFF)
    }

    mutating func rebuild(_ positions: [Vec3]) {
        var keyed: [(Int64, Int32)] = positions.enumerated().map { (key($0.element), Int32($0.offset)) }
        keyed.sort { $0.0 < $1.0 }
        order = keyed.map(\.1)
        ranges.removeAll(keepingCapacity: true)
        guard !keyed.isEmpty else { return }
        var start = 0
        for i in 1...keyed.count where i == keyed.count || keyed[i].0 != keyed[start].0 {
            ranges[keyed[start].0] = start..<i
            start = i
        }
    }

    func query(_ center: Vec3, radius: Float, positions: [Vec3]) -> [Int] {
        let lo = cell(center - Vec3(repeating: radius)), hi = cell(center + Vec3(repeating: radius))
        var out: [Int] = []
        let r2 = radius * radius
        for x in lo.x...hi.x { for y in lo.y...hi.y { for z in lo.z...hi.z {
            guard let r = ranges[key(SIMD3(x, y, z))] else { continue }
            for i in r {
                let v = Int(order[i])
                if simd_distance_squared(positions[v], center) <= r2 { out.append(v) }
            }
        }}}
        return out
    }
}

/// Live sculpting on a working copy of the mesh. The workspace turns finished strokes into a
/// non-destructive sculpt layer (see `SculptLayer`).
public final class SculptEngine {
    public private(set) var mesh: ClayMesh
    private var hash: SpatialHash
    private var settings = BrushSettings()
    private var lastDab: Vec3?
    private var lastDirection: Vec3?
    private var dabsSinceRebuild = 0
    private var strokeActive = false

    // Grab state
    private struct GrabTarget { var vertex: Int; var start: Vec3; var weight: Float; var mirrored: Bool }
    private var grabTargets: [GrabTarget] = []
    private var grabOrigin: Vec3 = .zero
    private var grabPlaneNormal: Vec3 = .zero

    public var isStroking: Bool { strokeActive }

    public init(mesh: ClayMesh) {
        self.mesh = mesh
        hash = SpatialHash(positions: mesh.positions, cellSize: 9)
    }

    public func replaceMesh(_ m: ClayMesh) {
        mesh = m
        hash = SpatialHash(positions: m.positions, cellSize: hash.cellSize)
    }

    // MARK: Strokes

    public func beginStroke(at hit: ClayMesh.Hit, viewDirection: Vec3, settings s: BrushSettings, pressure: Float) {
        settings = s
        strokeActive = true
        lastDab = nil
        lastDirection = nil
        if abs(hash.cellSize - s.radius) > s.radius * 0.5 {
            hash = SpatialHash(positions: mesh.positions, cellSize: s.radius)
        } else {
            hash.rebuild(mesh.positions)
        }
        if s.kind == .grab {
            beginGrab(hit: hit, viewDirection: viewDirection, pressure: pressure)
        } else {
            dab(at: hit.position, normal: hit.normal, pressure: pressure)
            lastDab = hit.position
        }
    }

    /// Continues the stroke along the pointer ray. Returns false when the pointer left the surface.
    @discardableResult
    public func continueStroke(ray: Ray, pressure: Float) -> Bool {
        guard strokeActive else { return false }
        if settings.kind == .grab { return updateGrab(ray: ray) }
        guard let hit = mesh.raycast(ray) else { return false }
        let r = effectiveRadius(pressure)
        let step = max(r * settings.spacing, 0.2)
        guard let from = lastDab else {
            dab(at: hit.position, normal: hit.normal, pressure: pressure); lastDab = hit.position; return true
        }
        let dist = simd_distance(from, hit.position)
        if dist < step { return true }
        let dir = (hit.position - from) / dist
        lastDirection = dir
        // Interpolate dabs evenly between the last dab and the new hit.
        let count = min(Int(dist / step), 24)
        for i in 1...count {
            let p = from + dir * (step * Float(i))
            dab(at: p, normal: hit.normal, pressure: pressure)
        }
        lastDab = from + dir * (step * Float(count))
        return true
    }

    public func endStroke() {
        strokeActive = false
        grabTargets.removeAll()
        mesh.recomputeNormals()
        hash.rebuild(mesh.positions)
    }

    private func effectiveRadius(_ pressure: Float) -> Float {
        settings.pressureRadius ? settings.radius * (0.35 + 0.65 * pressure) : settings.radius
    }

    private func effectiveStrength(_ pressure: Float) -> Float {
        settings.pressureStrength ? settings.strength * (0.2 + 0.8 * pressure) : settings.strength
    }

    private func dab(at center: Vec3, normal: Vec3, pressure: Float) {
        let r = effectiveRadius(pressure)
        let s = effectiveStrength(pressure)
        var centers = [(center, normal, lastDirection)]
        if settings.symmetryX && abs(center.x) > r * 0.15 {
            let m = Vec3(-1, 1, 1)
            centers.append((center * m, normal * m, lastDirection.map { $0 * m }))
        }
        var touched: [Int] = []
        for (c, n, d) in centers {
            let verts = hash.query(c, radius: r, positions: mesh.positions)
            let dab = BrushDab(center: c, normal: n, radius: r, strength: s, direction: d)
            SculptKernels.apply(settings.kind, invert: settings.invert, falloff: settings.falloff,
                                dab: dab, verts: verts, mesh: &mesh)
            touched += verts
        }
        if !touched.isEmpty { mesh.recomputeNormals(around: touched) }
        dabsSinceRebuild += 1
        if dabsSinceRebuild > 12 {
            hash.rebuild(mesh.positions)
            dabsSinceRebuild = 0
        }
    }

    // MARK: Grab

    private func beginGrab(hit: ClayMesh.Hit, viewDirection: Vec3, pressure: Float) {
        let r = effectiveRadius(pressure)
        grabOrigin = hit.position
        grabPlaneNormal = -viewDirection
        grabTargets = []
        for v in hash.query(hit.position, radius: r, positions: mesh.positions) {
            let w = settings.falloff.weight(simd_distance(mesh.positions[v], hit.position) / r)
            if w > 0 { grabTargets.append(GrabTarget(vertex: v, start: mesh.positions[v], weight: w * effectiveStrength(pressure) * 1.6, mirrored: false)) }
        }
        if settings.symmetryX && abs(hit.position.x) > r * 0.15 {
            let mc = hit.position * Vec3(-1, 1, 1)
            for v in hash.query(mc, radius: r, positions: mesh.positions) {
                let w = settings.falloff.weight(simd_distance(mesh.positions[v], mc) / r)
                if w > 0 { grabTargets.append(GrabTarget(vertex: v, start: mesh.positions[v], weight: w * effectiveStrength(pressure) * 1.6, mirrored: true)) }
            }
        }
    }

    private func updateGrab(ray: Ray) -> Bool {
        guard let p = ray.intersectPlane(point: grabOrigin, normal: grabPlaneNormal) else { return false }
        let delta = (p - grabOrigin) * (settings.invert ? -1 : 1)
        var touched: [Int] = []
        touched.reserveCapacity(grabTargets.count)
        for g in grabTargets {
            let d = g.mirrored ? delta * Vec3(-1, 1, 1) : delta
            mesh.positions[g.vertex] = g.start + d * min(g.weight, 1)
            touched.append(g.vertex)
        }
        mesh.recomputeNormals(around: touched)
        return true
    }
}

// MARK: - Non-destructive sculpt layer

/// Sculpt displacements stored per vertex in each vertex's local frame (tangent, bitangent,
/// normal) of the *input* mesh. When an upstream sketch or dimension changes, the loft is
/// rebuilt with the same topology and the layer is re-applied, so sculpted detail follows the
/// new shape instead of being lost.
public struct SculptLayer: Codable, Sendable {
    public var vertexCount: Int
    public var displacements: [Vec3]

    public init(vertexCount: Int) {
        self.vertexCount = vertexCount
        displacements = [Vec3](repeating: .zero, count: vertexCount)
    }

    static func frame(_ n: Vec3) -> (Vec3, Vec3, Vec3) {
        let up = Vec3(0, 1, 0)
        var t = simd_cross(up, n)
        if simd_length_squared(t) < 1e-6 { t = simd_cross(Vec3(1, 0, 0), n) }
        t = t.safeNormalized
        let b = simd_cross(n, t)
        return (t, b, n)
    }

    /// Records `sculpted − base` in base-mesh local frames.
    public mutating func capture(base: ClayMesh, sculpted: ClayMesh) {
        guard base.vertexCount == sculpted.vertexCount else { return }
        vertexCount = base.vertexCount
        displacements = (0..<base.vertexCount).map { i in
            let d = sculpted.positions[i] - base.positions[i]
            let (t, b, n) = SculptLayer.frame(base.normals[i])
            return Vec3(simd_dot(d, t), simd_dot(d, b), simd_dot(d, n))
        }
    }

    public func apply(to base: ClayMesh) -> ClayMesh? {
        guard base.vertexCount == vertexCount else { return nil }
        var m = base
        for i in 0..<vertexCount {
            let d = displacements[i]
            if d == .zero { continue }
            let (t, b, n) = SculptLayer.frame(base.normals[i])
            m.positions[i] += t * d.x + b * d.y + n * d.z
        }
        m.recomputeNormals()
        return m
    }

    public var isEmpty: Bool { !displacements.contains { $0 != .zero } }

    // Compact binary encoding (JSON arrays of 3 floats per vertex would be ~4× larger).
    enum CodingKeys: String, CodingKey { case vertexCount, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let count = try c.decode(Int.self, forKey: .vertexCount)
        vertexCount = count
        let data = try c.decode(Data.self, forKey: .data)
        var out = [Vec3](repeating: .zero, count: count)
        data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            for i in 0..<min(count, floats.count / 3) {
                out[i] = Vec3(floats[i * 3], floats[i * 3 + 1], floats[i * 3 + 2])
            }
        }
        displacements = out
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vertexCount, forKey: .vertexCount)
        var floats: [Float] = []
        floats.reserveCapacity(vertexCount * 3)
        for d in displacements { floats += [d.x, d.y, d.z] }
        try c.encode(floats.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .data)
    }
}
