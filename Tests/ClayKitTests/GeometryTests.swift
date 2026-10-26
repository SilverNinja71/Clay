import Testing
import Foundation
import simd
@testable import ClayKit

@Suite("Curves")
struct CurveTests {
    @Test func bezierEndpointsAndLength() {
        let line = CubicBezier.line(Vec2(0, 0), Vec2(30, 40))
        #expect(simd_distance(line.point(at: 0), Vec2(0, 0)) < 1e-5)
        #expect(simd_distance(line.point(at: 1), Vec2(30, 40)) < 1e-5)
        #expect(abs(line.length - 50) < 0.01)
    }

    @Test func circleIsRound() {
        let c = SketchPath.circle(center: Vec2(5, 5), radius: 20)
        for p in c.polyline(samplesPerSegment: 32) {
            #expect(abs(simd_distance(p, Vec2(5, 5)) - 20) < 0.01) // κ approximation error ≈ 0.027%
        }
    }

    @Test func fitterStaysWithinTolerance() {
        let trace = VaseGuide.handTrace(wobble: 0.4)
        let segs = BezierFitter.fit(trace, closed: true)
        #expect(!segs.isEmpty)
        #expect(segs.count < trace.count / 4, "fitting should compress the stroke")
        let path = SketchPath(segments: segs, closed: true)
        let guide = VaseGuide.silhouette()
        // Every fitted sample lies close to the clean guide (noise + tolerance).
        for p in path.polyline(samplesPerSegment: 8) {
            #expect(guide.distance(to: p) < 2.5)
        }
    }

    @Test func fitterKeepsCorners() {
        // An L-shaped stroke should come back with a sharp corner, not a rounded one.
        var pts: [Vec2] = []
        for i in 0...40 { pts.append(Vec2(Float(i), 0)) }
        for i in 1...40 { pts.append(Vec2(40, Float(i))) }
        let segs = BezierFitter.fit(pts, closed: false)
        let path = SketchPath(segments: segs, closed: false)
        #expect(path.distance(to: Vec2(40, 0)) < 1.0)
    }
}

@Suite("Loft")
struct LoftTests {
    func loftVase() throws -> ClayMesh {
        let p = LoftParameters(frontSketch: UUID(), sideSketch: UUID())
        return try LoftEngine.loft(front: VaseGuide.frontSketch, side: VaseGuide.sideSketch, parameters: p)
    }

    @Test func loftIsWatertightWithOutwardNormals() throws {
        let m = try loftVase()
        #expect(m.isWatertight)
        #expect(m.volume > 0)
        let b = m.bounds
        #expect(abs(b.size.y - 120) < 0.6)
        #expect(abs(b.size.x - 76) < 1.0)          // widest at the belly: 2 × 38
        #expect(abs(b.size.z - 76 * 0.86) < 1.0)   // side silhouette controls depth
    }

    @Test func openHalfProfileRevolves() throws {
        let half = SketchPath(segments: SketchPath.smoothCurve(through: VaseGuide.rightProfile, closed: false), closed: false)
        let m = try LoftEngine.loft(front: Sketch(paths: [half]), side: nil,
                                    parameters: LoftParameters(frontSketch: UUID(), sideSketch: nil))
        #expect(m.isWatertight)
        #expect(abs(m.bounds.size.x - m.bounds.size.z) < 0.5)
    }

    @Test func extrudeRectangle() {
        let s = Sketch(paths: [.rectangle(Vec2(-10, 0), Vec2(10, 30))])
        let m = ExtrudeEngine.extrude(sketch: s, plane: .front, parameters: ExtrudeParameters(sketch: UUID(), depth: 8))!
        #expect(m.isWatertight)
        #expect(abs(m.volume - 20 * 30 * 8) < 1)
    }
}

@Suite("Mesh operations")
struct MeshOpTests {
    let vase = try! LoftEngine.loft(front: VaseGuide.frontSketch, side: VaseGuide.sideSketch,
                                    parameters: LoftParameters(frontSketch: UUID(), sideSketch: UUID()))

    @Test func shellOpensTopAndStaysClosed() {
        let s = MeshOperations.shell(vase, parameters: ShellParameters(thickness: 3, openTop: true))
        #expect(s.isWatertight)
        #expect(s.volume > 0 && s.volume < vase.volume * 0.5)
    }

    @Test func splitCapsTheCut() {
        let s = MeshOperations.split(vase, parameters: SplitParameters(height: 60))
        #expect(s.isWatertight)
        #expect(abs(s.bounds.max.y - 60) < 0.01)
    }

    @Test func chamferShrinksBase() {
        let c = MeshOperations.edgeTreatment(vase, EdgeTreatment(style: .chamfer, edge: .bottom, size: 4))
        let before = vase.extent(atHeight: vase.bounds.min.y, band: 0.3)!.x
        let after = c.extent(atHeight: c.bounds.min.y, band: 0.3)!.x
        let wBefore: Float = before.upperBound - before.lowerBound
        let wAfter: Float = after.upperBound - after.lowerBound
        #expect(abs(wBefore - wAfter - 8) < 0.5)
        #expect(c.isWatertight)
    }

    @Test func subdivideAndRemeshStayWatertight() {
        let sub = MeshOperations.subdivide(vase)
        #expect(sub.triangleCount == vase.triangleCount * 4)
        #expect(sub.isWatertight)
        let r = VoxelRemesher.remesh(vase, parameters: RemeshParameters(voxelSize: 2, smoothing: 1))!
        #expect(r.isWatertight)
        #expect(abs(r.volume - vase.volume) / vase.volume < 0.06)
    }
}

@Suite("Sculpting")
struct SculptTests {
    @Test func clayBrushBuildsVolumeAndLayerReapplies() throws {
        let base = try LoftEngine.loft(front: VaseGuide.frontSketch, side: VaseGuide.sideSketch,
                                       parameters: LoftParameters(frontSketch: UUID(), sideSketch: UUID()))
        let engine = SculptEngine(mesh: base)
        var s = BrushSettings(); s.kind = .clay; s.radius = 10; s.strength = 0.8
        let ray = Ray(origin: Vec3(0, 45, 200), direction: Vec3(0, 0, -1))
        let hit = try #require(base.raycast(ray))
        engine.beginStroke(at: hit, viewDirection: Vec3(0, 0, -1), settings: s, pressure: 1)
        for k in 0..<20 {
            _ = engine.continueStroke(ray: Ray(origin: Vec3(Float(k) * 0.6, 45, 200), direction: Vec3(0, 0, -1)), pressure: 1)
        }
        engine.endStroke()
        #expect(engine.mesh.volume > base.volume)

        var layer = SculptLayer(vertexCount: base.vertexCount)
        layer.capture(base: base, sculpted: engine.mesh)
        let re = try #require(layer.apply(to: base))
        var maxErr: Float = 0
        for i in 0..<base.vertexCount { maxErr = max(maxErr, simd_distance(re.positions[i], engine.mesh.positions[i])) }
        #expect(maxErr < 1e-3)
    }

    @Test func smoothReducesRoughness() throws {
        var m = try LoftEngine.loft(front: VaseGuide.frontSketch, side: nil, parameters: LoftParameters(frontSketch: UUID(), sideSketch: nil))
        for i in m.positions.indices { m.positions[i] += m.normals[i] * (i % 2 == 0 ? 0.6 : -0.6) }
        m.recomputeNormals()
        let rough = m
        m.laplacianSmooth(iterations: 3, lambda: 0.5, mu: -0.53)
        func roughness(_ x: ClayMesh) -> Float {
            let nb = x.topology.neighbors
            var s: Float = 0
            for i in x.positions.indices where !nb[i].isEmpty {
                let avg = nb[i].reduce(Vec3.zero) { $0 + x.positions[Int($1)] } / Float(nb[i].count)
                s += simd_distance(avg, x.positions[i])
            }
            return s
        }
        #expect(roughness(m) < roughness(rough) * 0.5)
    }
}

@Suite("CAD")
struct CADTests {
    @Test func expressions() {
        #expect(UnitExpression.evaluate("65", defaultUnit: .mm) == 65)
        #expect(abs(UnitExpression.evaluate("6.5cm", defaultUnit: .mm)! - 65) < 1e-4)
        #expect(abs(UnitExpression.evaluate("2 in", defaultUnit: .mm)! - 50.8) < 1e-4)
        #expect(UnitExpression.evaluate("50 + 15", defaultUnit: .mm) == 65)
        #expect(UnitExpression.evaluate("(120/2) mm", defaultUnit: .cm) == 60)
        #expect(UnitExpression.evaluate("3", defaultUnit: .cm) == 30)
        #expect(UnitExpression.evaluate("abc", defaultUnit: .mm) == nil)
    }

    @Test func baseDiameterDrivesTheSketch() {
        var front = VaseGuide.frontSketch
        var side: Sketch? = VaseGuide.sideSketch
        #expect(abs(ProfileDimensionSolver.measure(.baseWidth, front: front, side: side)! - 50) < 0.2)
        ProfileDimensionSolver.apply(.baseWidth, target: 65, front: &front, side: &side)
        #expect(abs(ProfileDimensionSolver.measure(.baseWidth, front: front, side: side)! - 65) < 0.01)
        // The rim is far from the base and should barely move.
        #expect(abs(ProfileDimensionSolver.measure(.rimWidth, front: front, side: side)! - 40) < 0.5)
        ProfileDimensionSolver.apply(.height, target: 150, front: &front, side: &side)
        #expect(abs(ProfileDimensionSolver.measure(.height, front: front, side: side)! - 150) < 0.01)
    }

    @Test func constraintSolverDistanceAndHorizontal() {
        var path = SketchPath.polyline([Vec2(0, 0), Vec2(30, 4), Vec2(31, 40)], closed: false)
        path.id = UUID()
        let a = AnchorRef(path: path.id, index: 0), b = AnchorRef(path: path.id, index: 1), c = AnchorRef(path: path.id, index: 2)
        var sketch = Sketch(paths: [path], constraints: [
            .fixed(a, Vec2(0, 0)),
            .horizontal(a, b),
            .distance(a, b, 50),
            .perpendicular(a, b, b, c),
        ])
        let report = ConstraintSolver.solve(&sketch)
        #expect(report.converged)
        let p = sketch.paths[0].anchors.map(\.position)
        #expect(abs(p[1].y - p[0].y) < 1e-3)
        #expect(abs(simd_distance(p[0], p[1]) - 50) < 1e-3)
        #expect(abs(simd_dot((p[1] - p[0]).safeNormalized, (p[2] - p[1]).safeNormalized)) < 1e-3)
    }

    @Test func circleRadiusConstraint() {
        let c = SketchPath.circle(center: .zero, radius: 10)
        var s = Sketch(paths: [c], constraints: [.radius(c.id, 32.5)])
        ConstraintSolver.solve(&s)
        let pts = s.paths[0].polyline(samplesPerSegment: 8)
        let cen = s.paths[0].centroid
        for p in pts { #expect(abs(simd_distance(p, cen) - 32.5) < 0.05) }
    }

    @Test func timelineParametricRebuildKeepsSculpt() throws {
        var tl = Timeline.starter()
        tl.editSketch(.front) { $0 = VaseGuide.frontSketch }
        tl.editSketch(.side) { $0 = VaseGuide.sideSketch }
        tl.features.append(Feature(name: "Loft", kind: .loft(LoftParameters(frontSketch: tl.features[0].id, sideSketch: tl.features[1].id))))
        let ev = TimelineEvaluator()
        let base = try #require(ev.evaluate(tl))
        #expect(base.isWatertight)

        var layer = SculptLayer(vertexCount: base.vertexCount)
        var sculpted = base
        for i in sculpted.positions.indices where abs(sculpted.positions[i].y - 95) < 4 { sculpted.positions[i] -= sculpted.normals[i] * 1.5 }
        layer.capture(base: base, sculpted: sculpted)
        tl.features.append(Feature(name: "Sculpt", kind: .sculpt(layer)))
        tl.features.append(Feature(name: "Chamfer", kind: .edgeTreatment(EdgeTreatment(style: .chamfer, edge: .bottom, size: 2))))
        let v1 = try #require(ev.evaluate(tl))
        #expect(v1.isWatertight)

        // Change the base diameter: the sketches change and the whole chain re-evaluates.
        var front = tl.sketch(.front)!, side = tl.sketch(.side)
        ProfileDimensionSolver.apply(.baseWidth, target: 65, front: &front, side: &side)
        tl.editSketch(.front) { $0 = front }
        tl.editSketch(.side) { $0 = side! }
        let v2 = try #require(ev.evaluate(tl))
        #expect(v2.vertexCount == v1.vertexCount)
        let baseExtent = v2.extent(atHeight: v2.bounds.min.y + 2.5, band: 0.6)!.x
        #expect(baseExtent.upperBound - baseExtent.lowerBound > 58)
        for f in tl.features { #expect(ev.statuses[f.id] == .ok || ev.statuses[f.id]?.message != nil) }
        #expect(ev.statuses[tl.features[3].id] == .ok, "sculpt layer must survive the parametric edit")
    }
}
