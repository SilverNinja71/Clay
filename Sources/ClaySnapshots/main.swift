// Headless check of the whole Clay pipeline: drives the workspace in code, renders every screen
// to PNG (no window is ever shown), exports all formats and prints a report.
//
//   swift run ClaySnapshots <output-folder>

import ClayKit
import SwiftUI
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

func writePNG(_ img: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

// `ClaySnapshots --icon <file.png>`: renders the 1024×1024 app icon (used by Scripts/build-app.sh).
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--icon" {
    guard let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    // The logo is drawn with y growing downward, so flip the bitmap context first.
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    // macOS icons leave a margin around the rounded square (824 of 1024 px).
    ClayLogo.draw(in: CGRect(x: 100, y: 100, width: 824, height: 824), context: ctx)
    writePNG(ctx.makeImage()!, to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.temporaryDirectory.path)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
#if os(macOS)
_ = NSApplication.shared
NSApplication.shared.setActivationPolicy(.prohibited)   // no Dock icon, no windows
#endif

func save(_ img: CGImage?, _ name: String) {
    guard let img else { print("  ✗ \(name): no image"); return }
    writePNG(img, to: out.appendingPathComponent(name))
    print("  ✓ \(name) \(img.width)×\(img.height)")
}

func check(_ ok: Bool, _ what: String) { print("  \(ok ? "✓" : "✗ FAIL") \(what)") }

/// Draws a SwiftUI view with real AppKit controls into a bitmap, using a window that is never
/// put on screen. (SwiftUI's ImageRenderer can't draw native controls.)
@MainActor func snapshot<V: View>(_ view: V, _ size: CGSize) -> CGImage? {
    #if os(macOS)
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    window.contentView = nil
    return rep.cgImage
    #else
    let r = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    return r.cgImage
    #endif
}

let size = CGSize(width: 1380, height: 880)
let themes = StudioThemeStore(theme: .ceramic)
let store = ProjectStore(root: out.appendingPathComponent("store"))
let renderer = ClayRenderer()!

@MainActor func settle(_ s: WorkspaceState, seconds: Double = 3) async {
    for _ in 0..<Int(seconds * 60) { s.tick(1 / 60) }
    try? await Task.sleep(nanoseconds: 50_000_000)
}

@MainActor func screen(_ s: WorkspaceState, _ name: String) {
    s.viewportSize = size
    let viewport = s.mode == .sketch ? nil : renderer.renderImage(s.renderScene(), width: Int(size.width), height: Int(size.height))
    let view = WorkspaceView(state: s)
        .environment(themes)
        .environment(\.viewportSnapshot, viewport)
    save(snapshot(view, size), name)
}

@MainActor func render3D(_ s: WorkspaceState, _ name: String, camera: OrbitCamera? = nil) {
    var scene = s.renderScene()
    if let camera { scene.camera = camera }
    save(renderer.renderImage(scene, width: 1000, height: 760), name)
}

print("Clay headless check → \(out.path)")

// 1. Tutorial: front sketch with ghost
var doc = store.create(name: "Ceramic Vase")
let s = WorkspaceState(document: doc)
s.theme = themes.current
s.onSave = { d, img in store.save(d, thumbnail: img) }
s.viewportSize = size
let tutorial = TutorialEngine()
s.tutorial = tutorial
tutorial.start(in: s)
try? await Task.sleep(nanoseconds: 200_000_000)
print("1. Sketch")
check(s.mode == .sketch && tutorial.phase == .frontSketch, "tutorial opens on the front sketch")
// A wobbly hand trace near the guide should snap onto it.
s.sketchTool = .pencil
s.liveStroke = []
let trace = VaseGuide.handTrace(wobble: 1.2)
s.livePlane = .front
screen(s, "01-front-sketch-ghost.png")
var e = PointerEvent(phase: .down, location: .zero)
let t = s.sketchViewTransform(.front)
let canvas = CGSize(width: size.width, height: size.height)
for (i, p) in trace.enumerated() {
    e.phase = i == 0 ? .down : .dragged
    e.location = t.toView(p, size: canvas)
    s.sketchPointerForTesting(e, plane: .front)
}
e.phase = .up
s.sketchPointerForTesting(e, plane: .front)
check(s.timeline.sketch(.front)?.paths.count == 1, "freehand stroke became one Bézier path")
check(s.timeline.sketch(.front)?.paths.first?.closed == true, "stroke closed itself")
try? await Task.sleep(nanoseconds: 900_000_000)
check(tutorial.phase == .sideSketch, "tutorial advanced to the side sketch")
screen(s, "02-side-sketch-guides.png")
tutorial.showMe(in: s)
try? await Task.sleep(nanoseconds: 700_000_000)
check(tutorial.phase == .generate, "side sketch done → Generate step")
s.splitSketch = true
screen(s, "03-split-view-generate.png")
s.splitSketch = false

// 2. Loft
print("2. Loft")
s.generateClay()
check(s.stats.watertight, "lofted mesh is watertight (\(s.stats.triangles) triangles)")
s.tick(0.8)
render3D(s, "04-loft-reveal.png")
await settle(s)
screen(s, "05-model.png")

// 3. Sculpt
print("3. Sculpt")
try? await Task.sleep(nanoseconds: 2_200_000_000)
check(s.mode == .sculpt, "tutorial switched to Sculpt mode")
let volBefore = s.stats.volume
s.brush.kind = .clay
s.demoSculpt()
check(s.sculptStrokes >= 2, "clay strokes applied")
check(s.stats.volume != volBefore, "sculpting changed the volume (\(Int(volBefore)) → \(Int(s.stats.volume)) mm³)")
try? await Task.sleep(nanoseconds: 500_000_000)
check(tutorial.phase == .smooth, "tutorial advanced to Smooth")
s.demoSculpt(smoothOnly: true)
try? await Task.sleep(nanoseconds: 600_000_000)
check(tutorial.phase == .dimension, "smooth stroke → Dimension step")
s.brush.kind = .clay
await settle(s)
screen(s, "06-sculpt.png")
var neck = OrbitCamera.preset(.front, framing: s.mesh!.bounds)
neck.orthographic = false
render3D(s, "07-sculpt-closeup.png", camera: neck)

// 4. Dimensions
print("4. Dimension")
check(s.mode == .dimension, "in Dimension mode")
let base = s.calloutValue(.profile(.baseWidth)) ?? 0
check(abs(base - 50) < 0.5, "base diameter reads \(String(format: "%.1f", base)) mm")
screen(s, "08-dimension-50mm.png")
let sculptLayerBefore = s.timeline.features.first { if case .sculpt = $0.kind { return true }; return false }
s.editingCallout = .profile(.baseWidth)
s.setCallout(.profile(.baseWidth), value: 65)
let after = s.calloutValue(.profile(.baseWidth)) ?? 0
check(abs(after - 65) < 0.05, "base diameter driven to \(String(format: "%.2f", after)) mm")
check(s.statuses[sculptLayerBefore!.id] == .ok, "sculpt layer survived the parametric change")
try? await Task.sleep(nanoseconds: 1_300_000_000)
check(tutorial.phase == .cover, "tutorial advanced to the cover step")
s.editingCallout = .profile(.baseWidth)
screen(s, "09-dimension-65mm-editor.png")
s.editingCallout = nil

// 5. CAD features, keyboard
print("5. Features & keyboard")
s.setMode(.model)
s.perform(.shell)
s.perform(.chamfer)
s.editingCallout = nil
check(s.stats.watertight, "shell + chamfer keep the body watertight")
var top = OrbitCamera.preset(.threeQuarter, framing: s.mesh!.bounds)
top.pitch = 0.75
render3D(s, "10-shell-chamfer.png", camera: top)
let count = s.timeline.features.count
s.lastPointerForTesting = CGPoint(x: 600, y: 400)
for k: KeyStroke in [.char("g"), .char("z"), .char("2"), .char("0"), KeyStroke(.enter)] { s.handleKey(k) }
check(s.timeline.features.count == count + 1, "G Z 2 0 ⏎ added a Move feature")
if case .transform(let tp)? = s.timeline.features.last?.kind { check(abs(tp.translation.z - 20) < 0.01, "moved exactly 20 mm along Z") }
s.handleKey(KeyStroke(.character("z"), command: true))
check(s.timeline.features.count == count, "⌘Z undid it")
s.handleKey(KeyStroke(.tab))
check(s.mode == .sculpt, "Tab cycles Model → Sculpt")
s.handleKey(.char("i"))
check(s.brush.kind == .inflate, "I selects Inflate")
s.handleKey(KeyStroke(.tab)); s.handleKey(KeyStroke(.tab))
check(s.mode == .sketch, "Tab cycles on to Sketch")
s.handleKey(.char("3"))
check(s.activePlane == .side, "3 switches to the side plane")
s.setMode(.model)
s.bodySelected = true
s.modelTool = .rotate
await settle(s, seconds: 0.5)
screen(s, "11-model-gizmo-timeline.png")
s.radialMenu = RadialMenuState(location: CGPoint(x: 690, y: 450), hit: .zero)
screen(s, "12-radial-menu.png")
s.radialMenu = nil

// 6. Cover + library
print("6. Covers & library")
var cover = s.document.cover
cover.material = .glazedCeramic
cover.tint = CoverMaterial.glazedCeramic.defaultTint
cover.doodle = [[Vec2(0.25, 0.62), Vec2(0.35, 0.58), Vec2(0.45, 0.63), Vec2(0.55, 0.57), Vec2(0.65, 0.62)]]
s.saveCover(cover)
try? await Task.sleep(nanoseconds: 300_000_000)
check(tutorial.phase == .done, "cover saved → tutorial done")
screen(s, "13-tutorial-done.png")
let coverView = CoverLibraryView(cover: cover, thumbnail: s.thumbnail(), title: "Ceramic Vase", theme: themes.current, onSave: { _ in }, onCancel: {})
save(snapshot(coverView, CGSize(width: 680, height: 560)), "14-cover-library.png")
for (i, m) in CoverMaterial.allCases.enumerated() {
    var c = ProjectCover(); c.material = m; c.tint = m.defaultTint; c.emblem = ["leaf.fill", "star.fill", "hammer.fill", "gearshape.fill", "moon.stars.fill"][i]
    c.showThumbnail = i % 2 == 0
    var d = store.create(name: m.title, cover: c)
    d.timeline = s.timeline
    store.save(d, thumbnail: i % 2 == 0 ? s.thumbnail() : nil)
}
let lib = ProjectBrowserView(store: store, theme: themes.current, onOpen: { _ in }, onNew: {}, onTutorial: {})
    .environment(themes)
save(snapshot(lib, size), "15-library.png")

// 7. Exports
print("7. Exports")
let m = s.mesh!
let stl = MeshExporter.stl(m, name: "Vase")
check(stl.count == 84 + 50 * m.triangleCount, "STL size matches \(m.triangleCount) triangles")
try stl.write(to: out.appendingPathComponent("vase.stl"))
let obj = MeshExporter.obj(m, name: "Vase")
check(String(decoding: obj, as: UTF8.self).components(separatedBy: "\nf ").count - 1 == m.triangleCount, "OBJ has every face")
try obj.write(to: out.appendingPathComponent("vase.obj"))
let step = MeshExporter.step(m, name: "Vase")
let stepText = String(decoding: step, as: UTF8.self)
check(stepText.hasPrefix("ISO-10303-21;") && stepText.contains("FACETED_BREP") && stepText.hasSuffix("END-ISO-10303-21;\n"), "STEP file is well-formed (\(step.count / 1024) KB)")
try step.write(to: out.appendingPathComponent("vase.step"))
let (usd, ext) = try MeshExporter.usd(m, name: "Vase", color: themes.current.clay.linear)
check(usd.count > 1000, "USD exported as .\(ext) (\(usd.count / 1024) KB)")
try usd.write(to: out.appendingPathComponent("vase.\(ext)"))
let svg = MeshExporter.drawingSheet(front: s.timeline.sketch(.front)!, side: s.timeline.sketch(.side), name: "Vase", units: .mm)
try svg.write(to: out.appendingPathComponent("vase-sheet.svg"))
check(String(decoding: svg, as: UTF8.self).contains("<path"), "SVG drawing sheet has the sketches")

// 8. Reload from disk: parametric rebuild must reproduce the same mesh.
print("8. Save & reload")
s.saveNow()
let reloaded = WorkspaceState(document: store.load(s.document.id)!)
check(reloaded.stats.triangles == s.stats.triangles && abs(reloaded.stats.volume - s.stats.volume) < 1, "reloaded project rebuilds the same body")

// 9. Pen tool + clean vector export
print("9. Pen tool")
let pen = WorkspaceState(document: store.create(name: "Leaf"))
pen.theme = themes.current
pen.viewportSize = size
pen.selectSketchTool(.pen)
let pt = pen.sketchViewTransform(.front)
@MainActor func penEvent(_ phase: PointerEvent.Phase, _ p: Vec2) {
    pen.sketchPointerForTesting(PointerEvent(phase: phase, location: pt.toView(p, size: size)), plane: .front)
}
penEvent(.down, Vec2(0, 5)); penEvent(.up, Vec2(0, 5))
penEvent(.down, Vec2(32, 55)); penEvent(.dragged, Vec2(32, 80)); penEvent(.up, Vec2(32, 80))
penEvent(.down, Vec2(0, 115)); penEvent(.up, Vec2(0, 115))
penEvent(.down, Vec2(-32, 55)); penEvent(.dragged, Vec2(-32, 30)); penEvent(.up, Vec2(-32, 30))
penEvent(.moved, Vec2(-6, 12))
screen(pen, "17-pen-tool-drawing.png")
penEvent(.down, Vec2(0, 5)); penEvent(.up, Vec2(0, 5))
check(pen.timeline.sketch(.front)?.paths.first?.closed == true, "pen tool closed the leaf on its first point")
pen.selectSketchTool(.edit)
pen.sketchSelection = pen.timeline.sketch(.front)?.paths.first.map { SketchSelection(plane: .front, pathID: $0.id) }
screen(pen, "18-pen-tool-done.png")
if let svg = MeshExporter.vectorSVG([(.front, pen.timeline.sketch(.front)!)], name: "Leaf") {
    try svg.write(to: out.appendingPathComponent("leaf-vector.svg"))
    let text = String(decoding: svg, as: UTF8.self)
    check(text.contains(" C") && !text.contains("<text") && !text.contains("<rect"), "clean SVG is only Bézier curves")
}

// 10. Other themes
print("10. Themes")
for theme in [StudioTheme.darkSlate, .blueprint] {
    themes.current = theme
    s.theme = theme
    s.setMode(.sculpt)
    screen(s, "16-theme-\(theme.id).png")
}
print("Done.")
