import Foundation
import simd

// MARK: - Features

public struct SketchFeature: Codable, Sendable {
    public var plane: SketchPlane
    public var sketch: Sketch
    public init(plane: SketchPlane, sketch: Sketch = Sketch()) { self.plane = plane; self.sketch = sketch }
}

public enum FeatureKind: Codable, Sendable {
    case sketch(SketchFeature)
    case loft(LoftParameters)
    case extrude(ExtrudeParameters)
    case sculpt(SculptLayer)
    case edgeTreatment(EdgeTreatment)
    case shell(ShellParameters)
    case offset(Float)
    case split(SplitParameters)
    case transform(TransformParameters)
    case duplicate(TransformParameters)
    case remesh(RemeshParameters)
    case subdivide

    public var symbol: String {
        switch self {
        case .sketch: "pencil.and.outline"
        case .loft: "cylinder"
        case .extrude: "square.stack.3d.up"
        case .sculpt: "hand.draw"
        case .edgeTreatment(let e): e.style == .chamfer ? "square.on.square.dashed" : "circle.bottomhalf.filled"
        case .shell: "cube.transparent"
        case .offset: "arrow.up.left.and.arrow.down.right"
        case .split: "scissors"
        case .transform: "move.3d"
        case .duplicate: "plus.square.on.square"
        case .remesh: "circle.hexagongrid"
        case .subdivide: "square.grid.3x3"
        }
    }

    /// Body-creating features start or add to the mesh; modifiers need an existing mesh.
    var createsBody: Bool {
        switch self { case .loft, .extrude: true; default: false }
    }
}

public struct Feature: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: FeatureKind
    public var suppressed: Bool
    /// Bumped on every edit; the evaluator re-runs from the first feature whose revision changed.
    public var revision: UInt64

    public init(id: UUID = UUID(), name: String, kind: FeatureKind, suppressed: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.suppressed = suppressed
        self.revision = Revision.next()
    }

    enum CodingKeys: String, CodingKey { case id, name, kind, suppressed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(FeatureKind.self, forKey: .kind)
        suppressed = try c.decodeIfPresent(Bool.self, forKey: .suppressed) ?? false
        revision = Revision.next()
    }

    public mutating func edit(_ body: (inout FeatureKind) -> Void) {
        body(&kind)
        revision = Revision.next()
    }

    public var sketch: SketchFeature? {
        if case .sketch(let s) = kind { return s }
        return nil
    }
}

public enum FeatureStatus: Equatable, Sendable {
    case ok
    case warning(String)
    case error(String)
    case suppressed
    case rolledBack

    public var message: String? {
        switch self {
        case .warning(let m), .error(let m): m
        default: nil
        }
    }
}

// MARK: - Timeline

/// The ordered, non-destructive list of modelling steps:
/// [Front Sketch] → [Side Sketch] → [Loft] → [Sculpt] → [Chamfer] …
public struct Timeline: Codable, Sendable {
    public var features: [Feature]
    /// Rollback marker: only the first `marker` features are evaluated (nil = all).
    public var marker: Int?

    public init(features: [Feature] = [], marker: Int? = nil) { self.features = features; self.marker = marker }

    /// A new document: empty front and side sketches.
    public static func starter() -> Timeline {
        Timeline(features: [
            Feature(name: "Front Sketch", kind: .sketch(SketchFeature(plane: .front))),
            Feature(name: "Side Sketch", kind: .sketch(SketchFeature(plane: .side))),
        ])
    }

    public var activeCount: Int { min(marker ?? features.count, features.count) }

    public func index(of id: UUID) -> Int? { features.firstIndex { $0.id == id } }

    public func sketchFeatureIndex(_ plane: SketchPlane) -> Int? {
        features.firstIndex { $0.sketch?.plane == plane }
    }

    public func sketch(_ plane: SketchPlane) -> Sketch? {
        sketchFeatureIndex(plane).flatMap { features[$0].sketch?.sketch }
    }

    public var loftIndex: Int? {
        features.firstIndex { if case .loft = $0.kind { return true }; return false }
    }

    public mutating func editSketch(_ plane: SketchPlane, _ body: (inout Sketch) -> Void) {
        guard let i = sketchFeatureIndex(plane) else { return }
        features[i].edit { kind in
            if case .sketch(var s) = kind { body(&s.sketch); kind = .sketch(s) }
        }
    }

    /// A unique, human-friendly name like "Chamfer 2".
    public func nextName(_ base: String) -> String {
        let n = features.filter { $0.name.hasPrefix(base) }.count
        return n == 0 ? base : "\(base) \(n + 1)"
    }
}

// MARK: - Evaluation

/// Evaluates a timeline into a mesh, caching every step so edits only recompute what changed.
public final class TimelineEvaluator {
    private struct Entry {
        var id: UUID
        var revision: UInt64
        var suppressed: Bool
        var mesh: ClayMesh?
    }
    private var entries: [Entry] = []
    public private(set) var statuses: [UUID: FeatureStatus] = [:]
    public private(set) var result: ClayMesh?

    public init() {}

    @discardableResult
    public func evaluate(_ tl: Timeline) -> ClayMesh? {
        let active = tl.activeCount
        // First index whose inputs changed.
        var start = 0
        while start < min(entries.count, active) {
            let e = entries[start], f = tl.features[start]
            if e.id != f.id || e.revision != f.revision || e.suppressed != f.suppressed { break }
            start += 1
        }
        if start == active && entries.count >= active {
            entries.removeLast(entries.count - active)
            result = active > 0 ? entries[active - 1].mesh : nil
            refreshRolledBack(tl)
            return result
        }
        entries.removeLast(entries.count - start)
        var mesh: ClayMesh? = start > 0 ? entries[start - 1].mesh : nil
        for i in start..<active {
            let f = tl.features[i]
            if f.suppressed {
                statuses[f.id] = .suppressed
            } else {
                let (m, status) = Self.run(f, input: mesh, timeline: tl)
                mesh = m
                statuses[f.id] = status
            }
            entries.append(Entry(id: f.id, revision: f.revision, suppressed: f.suppressed, mesh: mesh))
        }
        refreshRolledBack(tl)
        result = mesh
        return mesh
    }

    private func refreshRolledBack(_ tl: Timeline) {
        for f in tl.features.dropFirst(tl.activeCount) { statuses[f.id] = .rolledBack }
    }

    /// The mesh feeding into the feature at `index` (for sculpt layers).
    public func meshBefore(_ index: Int) -> ClayMesh? {
        index > 0 && index - 1 < entries.count ? entries[index - 1].mesh : nil
    }

    /// Stores a result computed elsewhere (live sculpting) so the next evaluate() can reuse it.
    public func overrideResult(at index: Int, feature: Feature, mesh: ClayMesh) {
        guard index < entries.count else { return }
        entries[index] = Entry(id: feature.id, revision: feature.revision, suppressed: feature.suppressed, mesh: mesh)
        entries.removeLast(entries.count - index - 1)
        result = mesh
    }

    public func reset() { entries.removeAll(); statuses.removeAll(); result = nil }

    static func run(_ f: Feature, input: ClayMesh?, timeline tl: Timeline) -> (ClayMesh?, FeatureStatus) {
        switch f.kind {
        case .sketch(let s):
            if s.sketch.isEmpty { return (input, .ok) }
            let report = { () -> FeatureStatus in
                var copy = s.sketch
                let r = ConstraintSolver.solve(&copy)
                return r.converged ? .ok : .warning("Constraints conflict (residual \(String(format: "%.2f", r.residual)) mm)")
            }()
            return (input, report)

        case .loft(let p):
            guard let fi = tl.index(of: p.frontSketch), let front = tl.features[fi].sketch?.sketch else {
                return (input, .error("Front sketch is missing."))
            }
            let side = p.sideSketch.flatMap { tl.index(of: $0) }.flatMap { tl.features[$0].sketch?.sketch }
            do {
                let body = try LoftEngine.loft(front: front, side: (side?.isEmpty ?? true) ? nil : side, parameters: p)
                var m = input ?? .empty
                if m.isEmpty { m = body } else { m.append(body) }
                return (m, (side?.isEmpty ?? true) ? .warning("No side sketch — using round sections.") : .ok)
            } catch {
                return (input, .error(error.localizedDescription))
            }

        case .extrude(let p):
            guard let si = tl.index(of: p.sketch), let sf = tl.features[si].sketch else { return (input, .error("Sketch is missing.")) }
            guard let body = ExtrudeEngine.extrude(sketch: sf.sketch, plane: sf.plane, parameters: p) else {
                return (input, .error("Extrude needs a closed sketch loop."))
            }
            var m = input ?? .empty
            if m.isEmpty { m = body } else { m.append(body) }
            return (m, .ok)

        case .sculpt(let layer):
            guard let input else { return (nil, .error("Nothing to sculpt.")) }
            if layer.isEmpty { return (input, .ok) }
            if let m = layer.apply(to: input) { return (m, .ok) }
            return (input, .warning("Topology changed upstream; sculpt layer can't be re-applied."))

        default:
            guard let input, !input.isEmpty else { return (input, .error("Needs a body. Generate 3D Clay first.")) }
            switch f.kind {
            case .edgeTreatment(let e): return (MeshOperations.edgeTreatment(input, e), .ok)
            case .shell(let p): return (MeshOperations.shell(input, parameters: p), .ok)
            case .offset(let d): return (MeshOperations.offset(input, distance: d), .ok)
            case .split(let p):
                let b = input.bounds
                if p.height <= b.min.y || p.height >= b.max.y { return (input, .warning("Split plane is outside the body.")) }
                return (MeshOperations.split(input, parameters: p), .ok)
            case .transform(let t): return (MeshOperations.transform(input, t), .ok)
            case .duplicate(let t):
                var m = input
                m.append(MeshOperations.transform(input, t))
                return (m, .ok)
            case .remesh(let p):
                guard let m = VoxelRemesher.remesh(input, parameters: p) else { return (input, .error("Remesh failed.")) }
                return (m, .ok)
            case .subdivide:
                if input.triangleCount > 600_000 { return (input, .warning("Mesh is already very dense.")) }
                return (MeshOperations.subdivide(input), .ok)
            default:
                return (input, .ok)
            }
        }
    }
}
