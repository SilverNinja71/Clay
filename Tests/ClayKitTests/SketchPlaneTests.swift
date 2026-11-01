import Testing
import Foundation
import CoreGraphics
import simd
@testable import ClayKit

@Suite("Sketch planes")
struct SketchPlaneTests {

    func circle(_ r: Float) -> Sketch { Sketch(paths: [.circle(center: .zero, radius: r)]) }

    @Test func createAndTransformAPlane() {
        var p = SketchPlane(name: "Rib", origin: Vec3(10, 20, 30), normal: Vec3(0, 0, 2), up: Vec3(0, 1, 0.3))
        // The frame is orthonormal and right-handed (right = up × normal).
        #expect(abs(simd_length(p.normal) - 1) < 1e-5 && abs(simd_dot(p.normal, p.up)) < 1e-5)
        #expect(simd_distance(p.right, Vec3(1, 0, 0)) < 1e-5)
        // Local ↔ world round trip.
        let q = Vec2(12.5, -7)
        #expect(simd_distance(p.local(p.world(q)), q) < 1e-4)
        #expect(simd_distance(p.world(.zero), Vec3(10, 20, 30)) < 1e-5)

        // Rotate 90° about Y around the origin, then move it.
        var t = TransformParameters()
        t.pivot = p.origin
        t.rotationAxis = Vec3(0, 1, 0)
        t.rotationDegrees = 90
        t.translation = Vec3(0, 0, 5)
        p.apply(t)
        #expect(simd_distance(p.normal, Vec3(1, 0, 0)) < 1e-5)
        #expect(simd_distance(p.up, Vec3(0, 1, 0)) < 1e-5)
        #expect(simd_distance(p.origin, Vec3(10, 20, 35)) < 1e-4)
        // Built-in planes match the classic StandardPlane mapping.
        for s in [StandardPlane.front, .side, .top] {
            let sp = SketchPlane.standard(s)
            #expect(simd_distance(sp.world(Vec2(3, 4)), s.worldPoint(Vec2(3, 4))) < 1e-5)
        }
    }

    @Test func projectingARayOntoThePlane() throws {
        let p = SketchPlane(name: "Tilted", origin: Vec3(0, 0, 50), normal: Vec3(1, 0, 1), up: Vec3(0, 1, 0))
        let ray = Ray(origin: Vec3(5, 7, 200), direction: Vec3(-0.2, 0.1, -1))
        let hit = try #require(p.intersect(ray))
        let w = p.world(hit.local)
        #expect(abs(p.signedDistance(w)) < 1e-3, "the point lies on the plane")
        #expect(simd_distance(w, ray.at(hit.distance)) < 1e-3, "and on the ray")
        // Straight down the normal lands on the plane's own origin.
        let head = try #require(p.intersect(Ray(origin: p.origin + p.normal * 40, direction: -p.normal)))
        #expect(simd_length(head.local) < 1e-4)
        // A ray parallel to the plane misses.
        #expect(p.intersect(Ray(origin: Vec3(0, 0, 0), direction: Vec3(0, 1, 0))) == nil)
    }

    @Test func loftingTwoParallelPlanes() throws {
        let bottom = SketchPlane(name: "A", origin: .zero, normal: Vec3(0, 0, 1), up: Vec3(0, 1, 0), sketch: circle(20))
        let top = SketchPlane(name: "B", origin: Vec3(0, 0, 40), normal: Vec3(0, 0, 1), up: Vec3(0, 1, 0), sketch: circle(10))
        let m = try SectionLoftEngine.loft(planes: [top, bottom], parameters: SectionLoftParameters(planes: []))
        #expect(m.isWatertight)
        // Two sections loft into a cone frustum: V = π·h/3·(R² + Rr + r²).
        let expected = Float.pi * 40 / 3 * (400 + 200 + 100)
        #expect(abs(m.volume - expected) / expected < 0.02)
        #expect(abs(m.bounds.size.z - 40) < 0.01)
    }

    @Test func loftingAngledPlanes() throws {
        let a = SketchPlane(name: "A", origin: .zero, normal: Vec3(0, 1, 0), up: Vec3(0, 0, -1), sketch: circle(15))
        var b = SketchPlane(name: "B", origin: Vec3(0, 50, 0), normal: Vec3(0, 1, 0), up: Vec3(0, 0, -1),
                            sketch: Sketch(paths: [.rectangle(Vec2(-12, -8), Vec2(12, 8))]))
        var tilt = TransformParameters()
        tilt.pivot = b.origin
        tilt.rotationAxis = Vec3(1, 0, 0)
        tilt.rotationDegrees = 30
        b.apply(tilt)
        let c = SketchPlane(name: "C", origin: Vec3(0, 90, 10), normal: Vec3(0, 1, 0.4), up: Vec3(0, 0, -1), sketch: circle(8))
        let m = try SectionLoftEngine.loft(planes: [a, b, c], parameters: SectionLoftParameters(planes: []))
        #expect(m.isWatertight)
        #expect(m.volume > 0)
        #expect(m.bounds.size.y > 80)
    }

    @Test func oneClosedCurveInflates() throws {
        let p = SketchPlane(name: "Leaf", origin: .zero, normal: Vec3(0, 0, 1), up: Vec3(0, 1, 0), sketch: circle(30))
        let m = try SectionLoftEngine.loft(planes: [p], parameters: SectionLoftParameters(planes: []))
        #expect(m.isWatertight)
        #expect(m.bounds.size.z > 10 && m.bounds.size.x > 55)
        #expect(throws: SectionLoftEngine.LoftError.self) {
            try SectionLoftEngine.loft(planes: [SketchPlane(name: "Empty", origin: .zero, normal: Vec3(0, 0, 1), up: Vec3(0, 1, 0))],
                                       parameters: SectionLoftParameters(planes: []))
        }
    }

    @Test func projectsSavedBeforePlanesStillLoad() throws {
        // A sketch step as it was stored before positioned planes existed.
        let id = UUID()
        let path = SketchPath.polyline([Vec2(0, 0), Vec2(10, 0), Vec2(10, 10)], closed: true)
        let sketchJSON = String(decoding: try JSONEncoder().encode(Sketch(paths: [path])), as: UTF8.self)
        let json = """
        {"id":"\(id.uuidString)","name":"Side Sketch","suppressed":false,
         "kind":{"sketch":{"_0":{"plane":"side","sketch":\(sketchJSON)}}}}
        """
        let f = try JSONDecoder().decode(Feature.self, from: Data(json.utf8))
        let plane = try #require(f.sketch?.plane)
        #expect(plane.standard == .side)
        #expect(plane.id == id, "a plane's id is its feature's id")
        #expect(plane.curves.count == 1)
        #expect(simd_distance(plane.normal, Vec3(1, 0, 0)) < 1e-6)
        // And it round-trips in the new format.
        let again = try JSONDecoder().decode(Feature.self, from: try JSONEncoder().encode(f))
        #expect(again.sketch?.plane.standard == .side && again.sketch?.plane.curves.count == 1)
    }
}

@Suite("Sketch planes in the workspace")
@MainActor
struct SketchPlaneWorkflowTests {

    @Test func drawOnPositionedPlanesThenFormClay() throws {
        let s = WorkspaceState(document: ClayDocument(name: "Ribs"))
        s.viewportSize = CGSize(width: 1000, height: 800)
        // Three horizontal planes stacked up the Y axis, each with a closed curve.
        var ids: [UUID] = []
        for (i, r) in [Float(30), 22, 12].enumerated() {
            let id = s.addPlane(normal: Vec3(0, 1, 0), at: Vec3(0, Float(i) * 45, 0))
            s.commit { $0.editSketch(id: id) { $0.paths = [.circle(center: .zero, radius: r)] } }
            ids.append(id)
        }
        #expect(s.timeline.planes.count == 5, "front + side + three positioned planes")
        #expect(s.formsFromPlanes && s.canGenerate)
        s.formClay()
        let m = try #require(s.mesh)
        #expect(m.isWatertight)
        #expect(abs(m.bounds.size.y - 90) < 0.5)
        guard case .sectionLoft(let p)? = s.timeline.features.last?.kind else { Issue.record("no Form Clay step"); return }
        #expect(Set(p.planes) == Set(ids))

        // Moving a plane re-forms the clay (it's a parametric input).
        let before = m.bounds.size.y
        s.commit { $0.editPlane(ids[2]) { $0.origin.y += 20 } }
        #expect(abs((s.mesh?.bounds.size.y ?? 0) - before - 20) < 0.5)
        // Ctrl+Tab goes straight to sculpting.
        s.handleKey(KeyStroke(.tab, control: true))
        #expect(s.mode == .sculpt)
    }

    @Test func drawingInThe3DViewLandsOnTheActivePlane() throws {
        let s = WorkspaceState(document: ClayDocument(name: "3D"))
        s.viewportSize = CGSize(width: 1000, height: 800)
        let id = s.addPlane(normal: Vec3(1, 0, 1), at: Vec3(0, 40, 0))
        s.alignView(to: id)
        s.camera = try #require(s.cameraAnimator.goal)
        s.cameraAnimator.goal = nil
        s.selectSketchTool(.pencil)
        let plane = try #require(s.timeline.plane(id))
        // Trace a circle on the plane through the 3D view (world → screen → back onto the plane).
        let pts = (0...48).map { i -> CGPoint in
            let a = Float(i) / 48 * 2 * .pi
            return s.camera.project(plane.world(Vec2(cos(a), sin(a)) * 25), in: s.viewportSize)!
        }
        for (i, q) in pts.enumerated() {
            var e = PointerEvent(phase: i == 0 ? .down : .dragged, location: q)
            e.device = .mouse
            s.viewportPointer(e)
        }
        s.viewportPointer(PointerEvent(phase: .up, location: pts[pts.count - 1]))
        let drawn = try #require(s.timeline.plane(id)?.curves.first)
        #expect(drawn.closed)
        for q in drawn.polyline(samplesPerSegment: 8) { #expect(abs(simd_length(q) - 25) < 1.5) }

        // With nothing selected (Esc), G moves the plane itself.
        s.handleKey(KeyStroke(.escape))
        #expect(s.sketchSelection == nil)
        s.handleKey(.char("g")); s.handleKey(.char("z")); s.handleKey(.char("1")); s.handleKey(.char("0")); s.handleKey(KeyStroke(.enter))
        #expect(abs((s.timeline.plane(id)?.origin.z ?? 0) - 10) < 1e-3)
    }
}
