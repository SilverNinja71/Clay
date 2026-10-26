import SwiftUI
import Observation
import simd

// MARK: - Modes and tools

public enum WorkspaceMode: String, CaseIterable, Identifiable, Sendable {
    case sketch, model, sculpt, dimension
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var symbol: String {
        switch self {
        case .sketch: "pencil.tip"
        case .model: "cube"
        case .sculpt: "hand.point.up.left"
        case .dimension: "ruler"
        }
    }
    public var next: WorkspaceMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
    public var previous: WorkspaceMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + all.count - 1) % all.count]
    }
}

public enum SketchTool: String, CaseIterable, Identifiable, Sendable {
    case pencil, pen, line, circle, rectangle, edit, eraser, dimension
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .pencil: "Pencil"
        case .pen: "Pen"
        case .line: "Line"
        case .circle: "Circle"
        case .rectangle: "Rectangle"
        case .edit: "Edit points"
        case .eraser: "Eraser"
        case .dimension: "Dimension"
        }
    }
    public var symbol: String {
        switch self {
        case .pencil: "pencil.tip"
        case .pen: "pencil.tip.crop.circle.badge.plus"
        case .line: "line.diagonal"
        case .circle: "circle"
        case .rectangle: "rectangle"
        case .edit: "point.topleft.down.to.point.bottomright.curvepath"
        case .eraser: "eraser"
        case .dimension: "ruler"
        }
    }
    public var hotkey: String {
        switch self {
        case .pencil: "P"; case .pen: "⇧P"; case .line: "L"; case .circle: "C"; case .rectangle: "B"
        case .edit: "V"; case .eraser: "E"; case .dimension: "D"
        }
    }
}

public enum ModelTool: String, CaseIterable, Identifiable, Sendable {
    case select, move, rotate, scale
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .rotate: "arrow.triangle.2.circlepath"
        case .scale: "arrow.up.left.and.arrow.down.right"
        }
    }
}

public enum DimensionTool: String, Sendable { case inspect, measure }

public enum RadialAction: String, CaseIterable, Identifiable, Sendable {
    case extrude, fillet, chamfer, offset, shell, split, dimension
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var symbol: String {
        switch self {
        case .extrude: "square.stack.3d.up"
        case .fillet: "circle.bottomhalf.filled"
        case .chamfer: "square.on.square.dashed"
        case .offset: "arrow.up.left.and.arrow.down.right"
        case .shell: "cube.transparent"
        case .split: "scissors"
        case .dimension: "ruler"
        }
    }
}

public struct Toast: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var text: String
    public var symbol: String
}

public struct Measurement: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var a: Vec3
    public var b: Vec3
}

public struct RadialMenuState: Equatable, Sendable {
    public var location: CGPoint
    public var hit: Vec3
    public init(location: CGPoint, hit: Vec3) { self.location = location; self.hit = hit }
}

public struct SketchSelection: Equatable, Sendable {
    public var plane: SketchPlane
    public var pathID: UUID
    public var anchors: [Int] = []
    public init(plane: SketchPlane, pathID: UUID, anchors: [Int] = []) { self.plane = plane; self.pathID = pathID; self.anchors = anchors }
}

public struct ShapeDrag: Equatable, Sendable {
    public var start: Vec2
    public var end: Vec2
}

public struct MeshStats: Equatable, Sendable {
    public var vertices = 0
    public var triangles = 0
    public var watertight = false
    public var volume: Float = 0
    public var size: Vec3 = .zero
    init() {}
    init(_ m: ClayMesh?) {
        guard let m, !m.isEmpty else { return }
        vertices = m.vertexCount; triangles = m.triangleCount
        watertight = m.isWatertight; volume = m.volume; size = m.bounds.size
    }
}

// MARK: - Workspace state

/// The open project and everything the workspace UI shows: mode, tools, camera, selection,
/// live interactions, undo history and the evaluated mesh.
@MainActor @Observable
public final class WorkspaceState {

    // MARK: Document & evaluation

    public var document: ClayDocument
    public var timeline: Timeline {
        get { document.timeline }
        set { document.timeline = newValue }
    }
    @ObservationIgnored let evaluator = TimelineEvaluator()
    /// Current mesh (the live sculpt mesh while sculpting). Not observed — the renderer polls it.
    @ObservationIgnored public internal(set) var mesh: ClayMesh?
    /// Observable signal that the mesh changed (for overlays and stats).
    public internal(set) var meshRevision: UInt64 = 0
    public private(set) var statuses: [UUID: FeatureStatus] = [:]
    public internal(set) var stats = MeshStats()

    // MARK: Modes & tools

    public internal(set) var mode: WorkspaceMode = .sketch
    public var activePlane: SketchPlane = .front
    public var splitSketch = false
    public var sketchTool: SketchTool = .pencil
    public var modelTool: ModelTool = .select
    public var dimensionTool: DimensionTool = .inspect
    public var brush = BrushSettings()
    public var smoothHeld = false
    public var showWireframe = false
    public var showSketches = true
    public var emulateNumpad = true
    public var showInspector = true
    public var pencilSeen = false

    // MARK: Camera

    public var camera = OrbitCamera()
    @ObservationIgnored var cameraAnimator = CameraAnimator()
    public var viewportSize = CGSize(width: 900, height: 640)
    public var sketchViews: [SketchPlane: SketchViewTransform] = [:]
    @ObservationIgnored var sketchCanvasSizes: [SketchPlane: CGSize] = [:]

    // MARK: Selection & live interaction

    public var selectedFeatureID: UUID?
    public var bodySelected = false
    public var sketchSelection: SketchSelection?
    public var modal: ModalTransform?
    public var radialMenu: RadialMenuState?
    public var editingCallout: CalloutID?
    public var measurements: [Measurement] = []
    public var pendingMeasure: Vec3?
    public var pendingDimensionAnchors: [AnchorRef] = []
    public var liveStroke: [Vec2] = []
    public var livePlane: SketchPlane = .front
    public var livePolyline: [Vec2] = []
    /// Anchors of the curve being placed with the pen tool.
    public var livePen: [BezierAnchor] = []
    public var liveShape: ShapeDrag?
    public var sketchHover: Vec2?
    public var statusText = ""
    @ObservationIgnored var brushCursor: (center: Vec3, radius: Float)?
    @ObservationIgnored var lastViewportPointer = CGPoint(x: 450, y: 320)
    @ObservationIgnored var viewportDrag: ViewportDrag?
    @ObservationIgnored var sketchDrag: SketchDrag?
    public var loftReveal: Float?
    public var toast: Toast?
    public var hapticTick = 0
    public var successTick = 0

    // MARK: Sculpt

    @ObservationIgnored var sculptEngine: SculptEngine?
    @ObservationIgnored var sculptFeatureID: UUID?
    @ObservationIgnored var sculptBase: ClayMesh?
    @ObservationIgnored var strokeKind: BrushKind?
    public internal(set) var sculptStrokes = 0
    public internal(set) var smoothStrokes = 0

    // MARK: Undo

    @ObservationIgnored private var undoStack: [Timeline] = []
    @ObservationIgnored private var redoStack: [Timeline] = []
    public private(set) var canUndo = false
    public private(set) var canRedo = false

    // MARK: Presentation & hooks

    public var exportPresented = false
    public var coverEditorPresented = false
    public var shortcutsPresented = false
    public var tutorial: TutorialEngine?
    @ObservationIgnored public var theme: StudioTheme = .ceramic
    @ObservationIgnored public var onSave: ((ClayDocument, CGImage?) -> Void)?
    @ObservationIgnored public var onClose: (() -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var time: Float = 0
    @ObservationIgnored var toastTask: Task<Void, Never>?

    public init(document: ClayDocument) {
        self.document = document
        reevaluate()
        if let c = document.camera { camera = c } else if let m = mesh { camera = OrbitCamera().framing(m.bounds) }
        if mesh != nil { mode = .model }
    }

    // MARK: - Evaluation & history

    public var units: LengthUnit {
        get { document.units }
        set { document.units = newValue; scheduleSave() }
    }

    func reevaluate() {
        let m = evaluator.evaluate(timeline)
        mesh = m
        statuses = evaluator.statuses
        meshRevision = m?.revision ?? 0
        stats = MeshStats(m)
        if mode == .sculpt { syncSculptEngine() }
    }

    /// Applies an undoable change to the timeline and rebuilds what it affects.
    public func commit(_ change: (inout Timeline) -> Void) {
        pushUndo()
        change(&document.timeline)
        reevaluate()
        scheduleSave()
    }

    /// Records the current timeline so the next edits can be undone as one step.
    public func pushUndo() {
        undoStack.append(timeline)
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true; canRedo = false
    }

    /// An edit that is part of an ongoing gesture (call `pushUndo()` once when it starts).
    public func liveChange(_ change: (inout Timeline) -> Void) {
        change(&document.timeline)
        reevaluate()
        scheduleSave()
    }

    public func undo() {
        cancelTransientState()
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(timeline)
        document.timeline = prev
        canUndo = !undoStack.isEmpty; canRedo = true
        reevaluate()
        scheduleSave()
        showToast("Undo", symbol: "arrow.uturn.backward")
    }

    public func redo() {
        cancelTransientState()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(timeline)
        document.timeline = next
        canUndo = true; canRedo = !redoStack.isEmpty
        reevaluate()
        scheduleSave()
        showToast("Redo", symbol: "arrow.uturn.forward")
    }

    func cancelTransientState() {
        modal = nil
        radialMenu = nil
        liveStroke = []; livePolyline = []; livePen = []; liveShape = nil
        viewportDrag = nil; sketchDrag = nil
        editingCallout = nil
    }

    // MARK: - Features

    public func feature(_ id: UUID?) -> Feature? {
        guard let id, let i = timeline.index(of: id) else { return nil }
        return timeline.features[i]
    }

    /// Inserts a feature at the rollback marker (or the end) and selects it.
    @discardableResult
    public func appendFeature(_ f: Feature) -> UUID {
        commit { tl in
            let at = tl.activeCount
            tl.features.insert(f, at: at)
            if tl.marker != nil { tl.marker = at + 1 }
        }
        selectedFeatureID = f.id
        return f.id
    }

    public func editFeature(_ id: UUID, live: Bool = false, _ body: (inout FeatureKind) -> Void) {
        guard let i = timeline.index(of: id) else { return }
        if live {
            liveChange { $0.features[i].edit(body) }
        } else {
            commit { $0.features[i].edit(body) }
        }
    }

    public func deleteFeature(_ id: UUID) {
        guard let i = timeline.index(of: id) else { return }
        if timeline.features[i].sketch != nil {
            commit { $0.features[i].edit { if case .sketch(var s) = $0 { s.sketch = Sketch(); $0 = .sketch(s) } } }
            showToast("Sketch cleared", symbol: "eraser")
            return
        }
        if timeline.features[i].id == sculptFeatureID { sculptFeatureID = nil; sculptEngine = nil }
        commit { tl in
            tl.features.remove(at: i)
            if let m = tl.marker, m > i { tl.marker = m - 1 }
        }
        if selectedFeatureID == id { selectedFeatureID = nil }
        if mode == .sculpt && sculptFeatureID == nil { _ = enterSculpt() }
    }

    public func toggleSuppressed(_ id: UUID) {
        guard let i = timeline.index(of: id) else { return }
        commit { $0.features[i].suppressed.toggle(); $0.features[i].revision = Revision.next() }
    }

    /// Rolls the timeline marker back to just after `id` (nil = end).
    public func rollBack(to id: UUID?) {
        commit { tl in
            if let id, let i = tl.index(of: id), i < tl.features.count - 1 { tl.marker = i + 1 } else { tl.marker = nil }
        }
    }

    /// Opens the right editor for a timeline feature.
    public func openFeature(_ id: UUID) {
        guard let f = feature(id) else { return }
        selectedFeatureID = id
        switch f.kind {
        case .sketch(let s):
            activePlane = s.plane
            setMode(.sketch)
        case .sculpt:
            if timeline.index(of: id) == timeline.activeCount - 1 { setMode(.sculpt) } else { setMode(.model) }
        default:
            setMode(.model)
        }
    }

    // MARK: - Modes

    public func setMode(_ m: WorkspaceMode) {
        guard m != mode else { return }
        if modal != nil { modal = nil }
        radialMenu = nil
        editingCallout = nil
        liveStroke = []; livePolyline = []; livePen = []; liveShape = nil
        if m == .sculpt {
            guard enterSculpt() else { return }
        } else if mode == .sculpt {
            sculptEngine = nil
            brushCursor = nil
            // An untouched sculpt step is just clutter in the timeline.
            if let id = sculptFeatureID, let i = timeline.index(of: id), case .sculpt(let layer) = timeline.features[i].kind, layer.isEmpty {
                liveChange { $0.features.remove(at: i); if let m = $0.marker, m > i { $0.marker = m - 1 } }
                if selectedFeatureID == id { selectedFeatureID = nil }
            }
            sculptFeatureID = nil
        }
        let old = mode
        mode = m
        if old == .sketch && m != .sketch {
            // Start from the orthographic view the user was drawing in, then glide to 3/4.
            let b = sceneBounds
            camera = OrbitCamera.preset(activePlane == .side ? .right : .front, framing: b)
            cameraAnimator.goal = OrbitCamera.preset(.threeQuarter, framing: b)
        }
        tutorial?.handle(.modeChanged(m), in: self)
    }

    public func cycleMode(forward: Bool = true) {
        var m = forward ? mode.next : mode.previous
        if m == .sculpt && (mesh?.isEmpty ?? true) { m = forward ? m.next : m.previous }
        setMode(m)
    }

    public func setPlane(_ p: SketchPlane) {
        guard p != .top else { return }
        finishPen(closed: false)
        sketchSelection = nil
        livePolyline = []
        activePlane = p
    }

    // MARK: - Camera

    public var sceneBounds: AABB {
        if let m = mesh, !m.isEmpty { return m.bounds }
        var b = AABB.empty
        for plane in [SketchPlane.front, .side] {
            guard let s = timeline.sketch(plane), let sb = s.bounds else { continue }
            b.include(plane.worldPoint(sb.min)); b.include(plane.worldPoint(sb.max))
        }
        return b.isEmpty ? AABB(min: Vec3(-40, 0, -40), max: Vec3(40, 120, 40)) : b
    }

    public func setView(_ v: ViewPreset) {
        if mode == .sketch {
            switch v {
            case .front, .back: setPlane(.front)
            case .right, .left: setPlane(.side)
            default: break
            }
            return
        }
        var g = OrbitCamera.preset(v, framing: nil)
        g.target = camera.target
        g.distance = camera.distance
        g.fovY = camera.fovY
        cameraAnimator.goal = g
    }

    public func toggleOrtho() {
        camera.orthographic.toggle()
        showToast(camera.orthographic ? "Orthographic" : "Perspective", symbol: "camera.viewfinder")
    }

    public func frameAll() {
        if mode == .sketch { fitSketchView(activePlane); return }
        cameraAnimator.goal = camera.framing(sceneBounds)
    }

    /// Per-frame update from the renderer: camera glides and the loft reveal animation.
    public func tick(_ dt: Float) {
        time += dt
        if cameraAnimator.isAnimating {
            var c = camera
            _ = cameraAnimator.step(&c, dt: dt)
            camera = c
        }
        if let r = loftReveal {
            let n = r + dt / 1.7
            loftReveal = n >= 1 ? nil : n
        }
    }

    // MARK: - Loft ("Generate 3D Clay")

    public var canGenerate: Bool {
        guard let front = timeline.sketch(.front) else { return false }
        return !front.isEmpty && timeline.loftIndex == nil
    }

    public func generateClay() {
        guard let fi = timeline.sketchFeatureIndex(.front), !(timeline.features[fi].sketch?.sketch.isEmpty ?? true) else {
            showToast("Draw a front silhouette first", symbol: "pencil.tip")
            return
        }
        if timeline.loftIndex == nil {
            let si = timeline.sketchFeatureIndex(.side)
            let p = LoftParameters(frontSketch: timeline.features[fi].id, sideSketch: si.map { timeline.features[$0].id })
            appendFeature(Feature(name: "Loft", kind: .loft(p)))
        }
        guard let m = mesh, !m.isEmpty else {
            showToast(statuses.values.compactMap(\.message).first ?? "Couldn't build the shape", symbol: "exclamationmark.triangle")
            return
        }
        mode = .model
        bodySelected = true
        let b = m.bounds
        camera = OrbitCamera.preset(activePlane == .side ? .right : .front, framing: b)
        cameraAnimator.goal = OrbitCamera.preset(.threeQuarter, framing: b)
        loftReveal = 0
        successTick += 1
        tutorial?.handle(.generated, in: self)
    }

    // MARK: - Sculpt

    @discardableResult
    func enterSculpt() -> Bool {
        guard let m = mesh, !m.isEmpty else {
            showToast("Generate 3D Clay first", symbol: "cube")
            return false
        }
        let active = timeline.activeCount
        if active > 0, case .sculpt = timeline.features[active - 1].kind {
            sculptFeatureID = timeline.features[active - 1].id
        } else {
            let f = Feature(name: timeline.nextName("Sculpt"), kind: .sculpt(SculptLayer(vertexCount: m.vertexCount)))
            appendFeature(f)
            sculptFeatureID = f.id
        }
        syncSculptEngine()
        return sculptEngine != nil
    }

    func syncSculptEngine() {
        guard let id = sculptFeatureID, let i = timeline.index(of: id), i < timeline.activeCount else {
            sculptEngine = nil; return
        }
        guard let base = evaluator.meshBefore(i) else { sculptEngine = nil; return }
        if case .sculpt(let layer) = timeline.features[i].kind, layer.vertexCount != base.vertexCount {
            // The shape upstream changed topology: start a fresh layer on the new mesh.
            timeline.features[i].edit { $0 = .sculpt(SculptLayer(vertexCount: base.vertexCount)) }
            reevaluate()
            showToast("Sculpt layer reset for the new topology", symbol: "exclamationmark.triangle")
            return
        }
        sculptBase = base
        if let current = mesh {
            if let e = sculptEngine { e.replaceMesh(current) } else { sculptEngine = SculptEngine(mesh: current) }
        }
    }

    func sculptBegin(ray: Ray, pressure: Float, invert: Bool, smooth: Bool) -> Bool {
        guard let engine = sculptEngine, let hit = engine.mesh.raycast(ray) else { return false }
        var s = brush
        if smooth || smoothHeld { s.kind = .smooth }
        if invert { s.invert.toggle() }
        strokeKind = s.kind
        pushUndo()
        engine.beginStroke(at: hit, viewDirection: camera.forward, settings: s, pressure: pressure)
        mesh = engine.mesh
        brushCursor = (hit.position, s.radius)
        return true
    }

    func sculptDrag(ray: Ray, pressure: Float) {
        guard let engine = sculptEngine, engine.isStroking else { return }
        engine.continueStroke(ray: ray, pressure: pressure)
        mesh = engine.mesh
        if let h = engine.mesh.raycast(ray) { brushCursor = (h.position, brush.radius) }
    }

    func sculptEnd() {
        guard let engine = sculptEngine, engine.isStroking else { return }
        engine.endStroke()
        mesh = engine.mesh
        if let id = sculptFeatureID, let i = timeline.index(of: id), let base = sculptBase {
            var layer = SculptLayer(vertexCount: base.vertexCount)
            layer.capture(base: base, sculpted: engine.mesh)
            document.timeline.features[i].edit { $0 = .sculpt(layer) }
            evaluator.overrideResult(at: i, feature: timeline.features[i], mesh: engine.mesh)
        }
        meshRevision = engine.mesh.revision
        stats = MeshStats(engine.mesh)
        sculptStrokes += 1
        if strokeKind == .smooth { smoothStrokes += 1 }
        if let k = strokeKind { tutorial?.handle(.stroke(k), in: self) }
        scheduleSave()
    }

    /// Clay strokes around the vase neck, then a smoothing pass ("Show me" in the tutorial).
    public func demoSculpt(smoothOnly: Bool = false) {
        if mode != .sculpt { setMode(.sculpt) }
        guard let m = mesh else { return }
        let b = m.bounds
        let y = b.min.y + b.size.y * 0.79
        // Sweep across the visible width of the neck at that height.
        let span = m.extent(atHeight: y, band: max(b.size.y * 0.01, 0.5))?.x ?? (b.min.x...b.max.x)
        let saved = brush
        brush.kind = smoothOnly ? .smooth : .clay
        brush.radius = 7; brush.strength = 0.7
        for pass in 0..<(smoothOnly ? 1 : 2) {
            let z = b.max.z + 200
            let x0 = span.lowerBound * 0.6, x1 = span.upperBound * 0.6
            let start = Ray(origin: Vec3(x0, y + Float(pass) * 3, z), direction: Vec3(0, 0, -1))
            guard sculptBegin(ray: start, pressure: 1, invert: false, smooth: smoothOnly) else { continue }
            for k in 1...24 {
                let x = x0 + (x1 - x0) * Float(k) / 24
                sculptDrag(ray: Ray(origin: Vec3(x, y + Float(pass) * 3, z), direction: Vec3(0, 0, -1)), pressure: 1)
            }
            sculptEnd()
        }
        brush = saved
    }

    public func setBrush(_ k: BrushKind) {
        brush.kind = k
        showToast(k.title, symbol: k.symbol)
    }

    // MARK: - Model operations

    public func perform(_ action: RadialAction) {
        radialMenu = nil
        guard action == .extrude || action == .dimension || !(mesh?.isEmpty ?? true) else {
            showToast("Generate 3D Clay first", symbol: "cube"); return
        }
        let b = mesh?.bounds ?? sceneBounds
        switch action {
        case .extrude: extrude()
        case .chamfer:
            appendFeature(Feature(name: timeline.nextName("Chamfer"), kind: .edgeTreatment(EdgeTreatment(style: .chamfer, edge: .bottom, size: 3))))
        case .fillet:
            appendFeature(Feature(name: timeline.nextName("Fillet"), kind: .edgeTreatment(EdgeTreatment(style: .fillet, edge: .bottom, size: 4))))
        case .offset:
            appendFeature(Feature(name: timeline.nextName("Offset"), kind: .offset(1)))
        case .shell:
            appendFeature(Feature(name: timeline.nextName("Shell"), kind: .shell(ShellParameters(thickness: 3, openTop: true))))
        case .split:
            appendFeature(Feature(name: timeline.nextName("Split"), kind: .split(SplitParameters(height: b.min.y + b.size.y * 0.6))))
        case .dimension:
            setMode(.dimension)
            return
        }
        if action != .extrude, let id = selectedFeatureID { editingCallout = .feature(id) }
        hapticTick += 1
    }

    public func remesh() {
        guard mesh != nil else { return }
        appendFeature(Feature(name: timeline.nextName("Remesh"), kind: .remesh(RemeshParameters())))
        if mode == .sculpt { sculptFeatureID = nil; _ = enterSculpt() }
        showToast("Voxel remesh · \(stats.triangles) triangles", symbol: "circle.hexagongrid")
    }

    public func subdivide() {
        guard mesh != nil else { return }
        appendFeature(Feature(name: timeline.nextName("Subdivide"), kind: .subdivide))
        if mode == .sculpt { sculptFeatureID = nil; _ = enterSculpt() }
        showToast("Subdivided · \(stats.triangles) triangles", symbol: "square.grid.3x3")
    }

    /// E: extrudes the selected closed sketch path (or every closed path of the active plane).
    public func extrude() {
        let plane = sketchSelection?.plane ?? activePlane
        guard let si = timeline.sketchFeatureIndex(plane), let sketch = timeline.features[si].sketch?.sketch else { return }
        var ids: [UUID]? = nil
        if let sel = sketchSelection, let p = sketch.paths.first(where: { $0.id == sel.pathID }) {
            guard p.closed else { showToast("Extrude needs a closed shape", symbol: "exclamationmark.triangle"); return }
            ids = [p.id]
        }
        guard sketch.paths.contains(where: { $0.closed }) else {
            showToast("Draw a closed shape to extrude", symbol: "exclamationmark.triangle"); return
        }
        let depth = max(10, (sketch.bounds.map { min($0.max.x - $0.min.x, $0.max.y - $0.min.y) } ?? 20) * 0.4)
        let id = appendFeature(Feature(name: timeline.nextName("Extrude"),
                                       kind: .extrude(ExtrudeParameters(sketch: timeline.features[si].id, depth: depth, paths: ids))))
        if mode == .sketch { setMode(.model) }
        editingCallout = .feature(id)
    }

    // MARK: - Modal transforms

    public func beginModal(_ kind: ModalTransform.Kind, at pointer: CGPoint? = nil) {
        switch mode {
        case .model:
            guard let m = mesh, !m.isEmpty else { return }
            modal = ModalTransform(kind: kind, target: .body, pivot: m.bounds.center, pointer: pointer ?? lastViewportPointer)
        case .sketch:
            guard let sel = sketchSelection, let path = sketchPath(sel) else {
                showToast("Select a sketch curve first (V)", symbol: "cursorarrow"); return
            }
            let size = sketchCanvasSizes[sel.plane] ?? viewportSize
            let start = pointer ?? sketchViewTransform(sel.plane).toView(sketchHover ?? path.centroid, size: size)
            modal = ModalTransform(kind: kind, target: .sketchPath(sel.plane, sel.pathID), pivot: Vec3(path.centroid, z: 0), pointer: start)
        default:
            return
        }
        bodySelected = true
    }

    public func updateModal(pointer: CGPoint) {
        guard modal != nil else { return }
        modal?.pointer = pointer
        if case .duplicate(let id) = modal?.target, let t = modalTransform3D() {
            editFeature(id, live: true) { $0 = .duplicate(t) }
        }
        refreshModalStatus()
    }

    func refreshModalStatus() {
        guard let m = modal else { statusText = ""; return }
        switch m.target {
        case .body, .duplicate:
            statusText = m.describe(modalTransform3D() ?? TransformParameters(), units: units)
        case .sketchPath:
            statusText = m.describe(TransformParameters(), units: units).components(separatedBy: "  ").first.map { "\($0) · sketch" } ?? ""
        }
    }

    func modalTransform3D() -> TransformParameters? {
        guard let m = modal else { return nil }
        var t = m.transform3D(camera: camera, size: viewportSize)
        if case .duplicate = m.target, let b = mesh?.bounds {
            // Duplicates keep their initial side-by-side offset as the starting point.
            t.translation += Vec3(b.size.x * 1.15, 0, 0)
        }
        return t
    }

    func modalMap2D() -> ((Vec2) -> Vec2)? {
        guard let m = modal, case .sketchPath(let plane, _) = m.target else { return nil }
        let size = sketchCanvasSizes[plane] ?? viewportSize
        return m.transform2D(pivot2D: Vec2(m.pivot.x, m.pivot.y), view: sketchViewTransform(plane), size: size)
    }

    public func confirmModal() {
        guard let m = modal else { return }
        switch m.target {
        case .body:
            if let t = modalTransform3D(), !t.isIdentity {
                appendFeature(Feature(name: timeline.nextName(m.kind.title), kind: .transform(t)))
            }
        case .duplicate(let id):
            if let t = modalTransform3D() { editFeature(id) { $0 = .duplicate(t) } }
        case .sketchPath(let plane, let pid):
            if let f = modalMap2D() {
                commit { tl in tl.editSketch(plane) { s in
                    if let i = s.pathIndex(pid) { s.paths[i].transform(f) }
                } }
            }
        }
        modal = nil
        statusText = ""
        hapticTick += 1
    }

    public func cancelModal() {
        if case .duplicate(let id) = modal?.target { modal = nil; undoDuplicate(id) }
        modal = nil
        statusText = ""
    }

    private func undoDuplicate(_ id: UUID) {
        guard let i = timeline.index(of: id) else { return }
        liveChange { $0.features.remove(at: i) }
    }

    public func duplicate() {
        switch mode {
        case .model:
            guard let m = mesh, !m.isEmpty else { return }
            var t = TransformParameters()
            t.pivot = m.bounds.center
            t.translation = Vec3(m.bounds.size.x * 1.15, 0, 0)
            let id = appendFeature(Feature(name: timeline.nextName("Duplicate"), kind: .duplicate(t)))
            modal = ModalTransform(kind: .grab, target: .duplicate(id), pivot: t.pivot, pointer: lastViewportPointer)
            refreshModalStatus()
        case .sketch:
            guard let sel = sketchSelection, var p = sketchPath(sel) else { return }
            p.id = UUID()
            p.transform { $0 + Vec2(8, -8) }
            let copy = p
            commit { $0.editSketch(sel.plane) { $0.paths.append(copy) } }
            sketchSelection = SketchSelection(plane: sel.plane, pathID: copy.id)
            beginModal(.grab)
        default: break
        }
    }

    public func deleteSelection() {
        switch mode {
        case .sketch:
            guard let sel = sketchSelection else { return }
            commit { tl in tl.editSketch(sel.plane) { s in
                guard let i = s.pathIndex(sel.pathID) else { return }
                if sel.anchors.isEmpty || s.paths[i].anchors.count - sel.anchors.count < 2 {
                    s.paths.remove(at: i)
                    s.constraints.removeAll { c in c.anchorRefs.contains { $0.path == sel.pathID } || c.circlePaths.contains(sel.pathID) }
                } else {
                    for k in sel.anchors.sorted(by: >) { s.paths[i].anchors.remove(at: k) }
                    s.constraints.removeAll { c in c.anchorRefs.contains { $0.path == sel.pathID } }
                }
            } }
            sketchSelection = nil
        case .model, .sculpt:
            if let id = selectedFeatureID { deleteFeature(id) }
            else { showToast("Select a step in the timeline to delete it", symbol: "info.circle") }
        case .dimension:
            if measurements.isEmpty { return }
            measurements.removeAll(); pendingMeasure = nil
        }
    }

    // MARK: - Keyboard

    /// Handles a key stroke; returns true when Clay used it.
    @discardableResult
    public func handleKey(_ k: KeyStroke) -> Bool {
        let closed = sketchSelection.flatMap { sketchPath($0) }?.closed ?? false
        let ctx = KeymapContext(mode: mode, modalActive: modal != nil, emulateNumpad: emulateNumpad, closedPathSelected: closed)
        guard let cmd = BlenderKeymap.resolve(k, ctx) else { return false }
        perform(cmd)
        return true
    }

    public func perform(_ cmd: KeyCommand) {
        switch cmd {
        case .view(let v): setView(v)
        case .toggleOrtho: toggleOrtho()
        case .frameAll: frameAll()
        case .grab: beginModal(.grab)
        case .rotate: beginModal(.rotate)
        case .scale: beginModal(.scale)
        case .extrude: extrude()
        case .duplicate: duplicate()
        case .delete: deleteSelection()
        case .nextMode: cycleMode(forward: true)
        case .previousMode: cycleMode(forward: false)
        case .undo: undo()
        case .redo: redo()
        case .save: saveNow(); showToast("Saved", symbol: "checkmark.circle")
        case .export: exportPresented = true
        case .modalAxis(let a, let plane): modal?.setAxis(a, plane: plane); refreshModalStatus()
        case .modalInput(let c): modal?.type(c); refreshModalStatus()
        case .modalBackspace: modal?.backspace(); refreshModalStatus()
        case .modalConfirm: confirmModal()
        case .modalCancel: cancelModal()
        case .modalSwitch(let k): modal?.kind = k; modal?.numeric = ""; refreshModalStatus()
        case .brush(let b): setBrush(b)
        case .radius(let bigger): brush.radius = clamp(brush.radius * (bigger ? 1.15 : 1 / 1.15), 0.5, 80)
        case .strength(let up): brush.strength = clamp(brush.strength + (up ? 0.05 : -0.05), 0.02, 1)
        case .toggleSymmetry:
            brush.symmetryX.toggle()
            showToast(brush.symmetryX ? "X symmetry on" : "X symmetry off", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right")
        case .remesh: remesh()
        case .toggleWireframe: showWireframe.toggle()
        case .toggleInspector: showInspector.toggle()
        case .sketchTool(let t): selectSketchTool(t)
        case .finishShape: finishPolyline(closed: false); finishPen(closed: false)
        case .measureTool: dimensionTool = dimensionTool == .measure ? .inspect : .measure
        case .cancel:
            if !livePolyline.isEmpty || !livePen.isEmpty { livePolyline = []; livePen = [] }
            else if radialMenu != nil { radialMenu = nil }
            else if editingCallout != nil { editingCallout = nil }
            else { sketchSelection = nil; bodySelected = false; selectedFeatureID = nil; pendingDimensionAnchors = [] }
        }
    }

    // MARK: - Feedback

    public func showToast(_ text: String, symbol: String = "info.circle") {
        toast = Toast(text: text, symbol: symbol)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: - Saving

    public func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    public func saveNow() {
        saveTask?.cancel()
        document.camera = camera
        onSave?(document, thumbnail())
    }

    /// Off-screen 3/4 render of the model for the library card.
    public func thumbnail(size: Int = 480) -> CGImage? {
        guard let m = mesh, !m.isEmpty, let r = ClayRenderer() else { return nil }
        var s = RenderScene()
        s.mesh = m
        s.camera = OrbitCamera.preset(.threeQuarter, framing: m.bounds)
        s.camera.distance *= 0.95
        s.palette = theme.palette
        s.showGrid = false
        return r.renderImage(s, width: size, height: size)
    }

    public func close() {
        saveNow()
        onClose?()
    }

    // MARK: - Automation hooks (headless checks)

    public func sketchPointerForTesting(_ e: PointerEvent, plane: SketchPlane) { sketchPointer(e, plane: plane) }
    public var lastPointerForTesting: CGPoint {
        get { lastViewportPointer }
        set { lastViewportPointer = newValue }
    }

    // MARK: - Render scene

    public func renderScene() -> RenderScene {
        var s = RenderScene()
        s.mesh = mesh
        s.camera = camera
        s.palette = theme.palette
        s.showWireframe = showWireframe
        s.time = time
        if let r = loftReveal { s.reveal = 1 - pow(1 - r, 3) }
        if mode == .sculpt, let c = brushCursor { s.brush = c }
        if let m = modal, m.target == .body, let t = modalTransform3D() { s.modelMatrix = t.matrix }

        let accent = theme.accent.linear
        let blue = theme.guideInk.linear
        let showCurves = showSketches && mode != .sculpt
        for plane in [SketchPlane.front, .side] {
            guard let sk = timeline.sketch(plane) else { continue }
            let color = plane == .front ? accent : Vec4(blue.x, blue.y, blue.z, 1)
            for path in sk.paths {
                let pts = path.polyline(samplesPerSegment: 20).map { plane.worldPoint($0) }
                if s.reveal != nil {
                    s.overlayCurves.append(CurveStroke(points: pts, color: color, width: 3.5, closed: path.closed))
                } else if showCurves {
                    s.curves.append(CurveStroke(points: pts, color: Vec4(color.x, color.y, color.z, 0.9), width: 2, closed: path.closed))
                }
            }
        }
        for m in measurements {
            s.overlayCurves.append(CurveStroke(points: [m.a, m.b], color: Vec4(accent.x, accent.y, accent.z, 0.9), width: 2))
        }
        return s
    }
}
