import Foundation
import simd

public enum BrushKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case clay, clayStrips, draw, grab, smooth, crease, pinch, flatten, scrape, inflate

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .clay: "Clay"
        case .clayStrips: "Clay Strips"
        case .draw: "Draw"
        case .grab: "Grab"
        case .smooth: "Smooth"
        case .crease: "Crease"
        case .pinch: "Pinch"
        case .flatten: "Flatten"
        case .scrape: "Scrape"
        case .inflate: "Inflate"
        }
    }

    public var symbol: String {
        switch self {
        case .clay: "hand.point.up.left.fill"
        case .clayStrips: "line.3.horizontal"
        case .draw: "scribble"
        case .grab: "hand.draw.fill"
        case .smooth: "drop.fill"
        case .crease: "chevron.down"
        case .pinch: "arrow.down.right.and.arrow.up.left"
        case .flatten: "rectangle.compress.vertical"
        case .scrape: "minus.rectangle"
        case .inflate: "circle.dashed.inset.filled"
        }
    }

    /// Blender-style hotkey shown in tooltips (handled by the keymap in Sculpt mode).
    public var hotkey: String {
        switch self {
        case .clay: "C"
        case .clayStrips: "⇧C"
        case .draw: "X"
        case .grab: "G"
        case .smooth: "S"
        case .crease: "⇧K"
        case .pinch: "P"
        case .flatten: "⇧T"
        case .scrape: "⇧S"
        case .inflate: "I"
        }
    }

    public var inverseTitle: String {
        switch self {
        case .inflate: "Deflate"
        case .clay, .clayStrips, .draw: "Carve"
        case .crease: "Ridge"
        case .pinch: "Magnify"
        case .scrape: "Fill"
        default: "Invert"
        }
    }
}

public enum Falloff: String, Codable, CaseIterable, Sendable {
    case smooth, sphere, root, sharp, linear, constant

    /// Weight for normalised distance t ∈ [0, 1] (1 at the centre, 0 at the rim).
    @inlinable public func weight(_ t: Float) -> Float {
        if t >= 1 { return 0 }
        let x = max(0, t)
        switch self {
        case .smooth: let s = 1 - x; return s * s * (3 - 2 * s)
        case .sphere: return sqrt(max(0, 1 - x * x))
        case .root: return sqrt(1 - x)
        case .sharp: return (1 - x) * (1 - x)
        case .linear: return 1 - x
        case .constant: return 1
        }
    }
}

public struct BrushSettings: Codable, Equatable, Sendable {
    public var kind: BrushKind = .clay
    public var radius: Float = 9          // mm
    public var strength: Float = 0.5      // 0…1
    public var falloff: Falloff = .smooth
    public var invert = false
    public var symmetryX = true
    public var pressureStrength = true
    public var pressureRadius = false
    public var spacing: Float = 0.12      // dab spacing as a fraction of the radius
    public init() {}
}

/// One brush application at a point on the surface.
struct BrushDab {
    var center: Vec3
    var normal: Vec3
    var radius: Float
    var strength: Float
    var direction: Vec3?     // stroke direction (clay strips)
}

/// The per-vertex deformation kernels. Each takes the vertices inside the dab and moves them.
enum SculptKernels {

    /// Area plane: falloff-weighted average position and normal of the vertices under the brush.
    static func areaPlane(_ mesh: ClayMesh, _ verts: [Int], _ dab: BrushDab, _ falloff: Falloff) -> (center: Vec3, normal: Vec3) {
        var c = Vec3.zero, n = Vec3.zero, w: Float = 0
        for v in verts {
            let d = simd_distance(mesh.positions[v], dab.center) / dab.radius
            let f = falloff.weight(d)
            c += mesh.positions[v] * f; n += mesh.normals[v] * f; w += f
        }
        guard w > 0 else { return (dab.center, dab.normal) }
        let nn = n.safeNormalized
        return (c / w, nn == .zero ? dab.normal : nn)
    }

    static func apply(_ kind: BrushKind, invert: Bool, falloff: Falloff, dab: BrushDab,
                      verts: [Int], mesh: inout ClayMesh) {
        guard !verts.isEmpty else { return }
        let r = dab.radius, s = dab.strength
        let sign: Float = invert ? -1 : 1
        let plane = areaPlane(mesh, verts, dab, falloff)
        let n = plane.normal

        // Distances are computed once from the pre-dab positions.
        let weights: [Float] = verts.map { v in falloff.weight(simd_distance(mesh.positions[v], dab.center) / r) }

        switch kind {
        case .draw:
            for (k, v) in verts.enumerated() where weights[k] > 0 {
                mesh.positions[v] += n * (sign * s * 0.09 * r * weights[k])
            }

        case .inflate:
            for (k, v) in verts.enumerated() where weights[k] > 0 {
                mesh.positions[v] += mesh.normals[v] * (sign * s * 0.07 * r * weights[k])
            }

        case .clay, .clayStrips:
            // Pull vertices up to a plane hovering just above the surface; they stop when they
            // reach it, which gives clay its "building up in layers" resistance.
            let offset = sign * r * 0.16 * s
            let planePoint = plane.center + n * offset
            var t1 = Vec3.zero, t2 = Vec3.zero
            if kind == .clayStrips {
                let dir = (dab.direction ?? anyPerpendicular(n))
                t1 = (dir - n * simd_dot(dir, n)).safeNormalized
                if t1 == .zero { t1 = anyPerpendicular(n) }
                t2 = simd_cross(n, t1)
            }
            for (k, v) in verts.enumerated() {
                let p = mesh.positions[v]
                var w = weights[k]
                if kind == .clayStrips {
                    let local = p - dab.center
                    let sq = max(abs(simd_dot(local, t1)), abs(simd_dot(local, t2))) / r
                    w = sq < 1 ? 1 - smoothstep(0.6, 1.0, sq) : 0
                }
                guard w > 0 else { continue }
                let dist = simd_dot(p - planePoint, n)
                if (sign > 0 && dist < 0) || (sign < 0 && dist > 0) {
                    mesh.positions[v] = p - n * (dist * w * min(1, 0.5 + s * 0.5))
                }
            }

        case .smooth:
            let nb = mesh.topology.neighbors
            let original = mesh.positions
            for (k, v) in verts.enumerated() where weights[k] > 0 && !nb[v].isEmpty {
                var avg = Vec3.zero
                for j in nb[v] { avg += original[Int(j)] }
                avg /= Float(nb[v].count)
                mesh.positions[v] = original[v] + (avg - original[v]) * clamp(weights[k] * (0.25 + s * 0.75), 0, 1)
            }

        case .pinch:
            for (k, v) in verts.enumerated() where weights[k] > 0 {
                var toC = dab.center - mesh.positions[v]
                toC -= n * simd_dot(toC, n)
                mesh.positions[v] += toC * (sign * s * 0.22 * weights[k])
            }

        case .crease:
            // Pinch toward the stroke line and push in along the normal: a sharp valley.
            for (k, v) in verts.enumerated() where weights[k] > 0 {
                let w = weights[k]
                var toC = dab.center - mesh.positions[v]
                toC -= n * simd_dot(toC, n)
                mesh.positions[v] += toC * (s * 0.18 * w) - n * (sign * s * 0.05 * r * w * w)
            }

        case .flatten, .scrape:
            for (k, v) in verts.enumerated() where weights[k] > 0 {
                let p = mesh.positions[v]
                let dist = simd_dot(p - plane.center, n)
                if kind == .scrape {
                    // Scrape removes only what sticks out; inverted it fills only hollows.
                    if (sign > 0 && dist <= 0) || (sign < 0 && dist >= 0) { continue }
                }
                mesh.positions[v] = p - n * (dist * weights[k] * clamp(s, 0.05, 1) * 0.5)
            }

        case .grab:
            break // handled by SculptEngine (it needs the stroke's start state)
        }
    }
}
