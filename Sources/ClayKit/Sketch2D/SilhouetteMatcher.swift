import Foundation
import simd

/// Projects alignment guides from one orthographic sketch onto the other, like the construction
/// lines a draughtsperson carries across between front and side elevations.
public enum SilhouetteMatcher {

    public struct Guide: Equatable, Sendable {
        public enum Strength: Sendable { case major, minor }
        public var height: Float
        public var label: String
        public var strength: Strength
    }

    /// Guides at the other sketch's top, bottom, widest point, waist and anchor heights.
    public static func guides(from other: Sketch) -> [Guide] {
        guard let p = SilhouetteProfile(sketch: other) else { return [] }
        var out: [Guide] = [
            Guide(height: p.vRange.lowerBound, label: "Base", strength: .major),
            Guide(height: p.vRange.upperBound, label: "Top", strength: .major),
        ]
        let (_, widestAt) = p.maxWidth
        out.append(Guide(height: widestAt, label: "Widest", strength: .major))
        if let waist = waist(p, above: widestAt) {
            out.append(Guide(height: waist, label: "Waist", strength: .major))
        }
        // Feature marks: anchor heights not already covered by a major guide.
        for path in other.paths {
            for a in path.anchors {
                let y = a.position.y
                if out.contains(where: { abs($0.height - y) < 2 }) { continue }
                out.append(Guide(height: y, label: "", strength: .minor))
            }
        }
        return out.sorted { $0.height < $1.height }
    }

    /// Narrowest point between `above` and the top (a vase neck).
    static func waist(_ p: SilhouetteProfile, above: Float) -> Float? {
        var best: (w: Float, y: Float)?
        let top = p.vRange.upperBound
        guard top - above > 4 else { return nil }
        for i in 1..<60 {
            let y = above + (top - above) * Float(i) / 60
            guard let e = p.extent(at: y) else { continue }
            let w = e.upperBound - e.lowerBound
            if best == nil || w < best!.w { best = (w, y) }
        }
        guard let b = best, b.y < top - (top - above) * 0.05 else { return nil }
        return b.y
    }

    /// Difference in total height between the two silhouettes (nil if either is missing).
    public static func heightMismatch(front: Sketch, side: Sketch) -> Float? {
        guard let a = SilhouetteProfile(sketch: front), let b = SilhouetteProfile(sketch: side) else { return nil }
        return max(abs(a.vRange.lowerBound - b.vRange.lowerBound), abs(a.vRange.upperBound - b.vRange.upperBound))
    }

    /// Stretches `side` vertically so its base and top line up with `front`.
    public static func matchHeights(front: Sketch, side: inout Sketch) {
        guard let a = SilhouetteProfile(sketch: front), let b = SilhouetteProfile(sketch: side), b.height > 1e-3 else { return }
        let k = a.height / b.height
        side.transformAll { Vec2($0.x, a.vRange.lowerBound + ($0.y - b.vRange.lowerBound) * k) }
    }
}
