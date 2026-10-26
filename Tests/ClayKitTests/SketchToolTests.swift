import Testing
import Foundation
import CoreGraphics
import simd
@testable import ClayKit

@Suite("Sketch tools")
@MainActor
struct SketchToolTests {
    let state: WorkspaceState

    init() {
        state = WorkspaceState(document: ClayDocument(name: "Test"))
        state.viewportSize = CGSize(width: 1000, height: 800)
    }

    private func send(_ phase: PointerEvent.Phase, _ p: Vec2, clicks: Int = 1, option: Bool = false) {
        var e = PointerEvent(phase: phase, location: state.sketchViewTransform(.front).toView(p, size: state.viewportSize))
        e.clickCount = clicks
        if option { e.modifiers = .option }
        state.sketchPointerForTesting(e, plane: .front)
    }

    private func click(_ p: Vec2, clicks: Int = 1) { send(.down, p, clicks: clicks); send(.up, p) }

    @Test func penClicksAndDragsMakeAClosedBezier() throws {
        state.selectSketchTool(.pen)
        click(Vec2(-20, 10))                       // corner
        send(.down, Vec2(20, 10))                  // smooth point: drag pulls out handles
        send(.dragged, Vec2(20, 25))
        send(.up, Vec2(20, 25))
        click(Vec2(0, 50))                         // corner
        click(Vec2(-20, 10))                       // back on the first point closes the shape
        let path = try #require(state.timeline.sketch(.front)?.paths.last)
        #expect(path.closed)
        #expect(path.kind == .pen)
        #expect(path.anchors.count == 3)
        #expect(path.anchors[0].outHandle == .zero)
        #expect(simd_distance(path.anchors[1].outHandle, Vec2(0, 15)) < 0.01)
        #expect(simd_distance(path.anchors[1].inHandle, Vec2(0, -15)) < 0.01)
        #expect(state.livePen.isEmpty)
    }

    @Test func optionDragBreaksTheHandle() throws {
        state.selectSketchTool(.pen)
        click(Vec2(-20, 10))
        send(.down, Vec2(20, 10))
        send(.dragged, Vec2(30, 10), option: true)
        send(.up, Vec2(30, 10))
        state.perform(.finishShape)
        let a = try #require(state.timeline.sketch(.front)?.paths.last?.anchors[1])
        #expect(a.outHandle == Vec2(10, 0))
        #expect(a.inHandle == .zero)
    }

    @Test func doubleClickAndToolSwitchFinishOpenCurves() throws {
        state.selectSketchTool(.pen)
        click(Vec2(-20, 10)); click(Vec2(10, 30)); click(Vec2(10, 30), clicks: 2)
        #expect(state.timeline.sketch(.front)?.paths.count == 1)
        #expect(state.timeline.sketch(.front)?.paths.last?.closed == false)
        click(Vec2(-30, 60)); click(Vec2(30, 60))
        state.selectSketchTool(.edit)
        #expect(state.timeline.sketch(.front)?.paths.count == 2)
        // Esc throws away a curve in progress.
        state.selectSketchTool(.pen)
        click(Vec2(0, 90)); click(Vec2(20, 90))
        state.perform(.cancel)
        #expect(state.livePen.isEmpty)
        #expect(state.timeline.sketch(.front)?.paths.count == 2)
    }

    @Test func cleanSVGHasOnlyCurves() throws {
        let data = try #require(MeshExporter.vectorSVG([(.front, VaseGuide.frontSketch), (.side, VaseGuide.sideSketch)], name: "Vase"))
        let svg = String(decoding: data, as: UTF8.self)
        #expect(svg.components(separatedBy: "<path").count - 1 == 2)
        #expect(!svg.contains("<rect") && !svg.contains("<text"))
        #expect(svg.contains("fill=\"none\""))
        #expect(svg.contains("<g id=\"front\">") && svg.contains("<g id=\"side\">"))
        // 1:1 millimetres: front width + 20 mm gap + side width + 2 mm margins.
        let fb = try #require(VaseGuide.frontSketch.bounds), sb = try #require(VaseGuide.sideSketch.bounds)
        let expected = (fb.max.x - fb.min.x) + 20 + (sb.max.x - sb.min.x) + 4
        #expect(svg.contains("width=\"\(String(format: "%.2f", expected))mm\""))
        #expect(MeshExporter.vectorSVG([(.front, Sketch())], name: "Empty") == nil)
    }
}
