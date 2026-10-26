import SwiftUI
import MetalKit
import simd

// MARK: - Viewport view

/// Off-screen render used instead of the live Metal view (headless screenshots, previews).
struct ViewportSnapshotKey: EnvironmentKey { static let defaultValue: CGImage? = nil }
public extension EnvironmentValues {
    var viewportSnapshot: CGImage? {
        get { self[ViewportSnapshotKey.self] }
        set { self[ViewportSnapshotKey.self] = newValue }
    }
}

/// The interactive 3D viewport: Metal rendering underneath, pointer capture on top.
public struct ClayViewportView: View {
    let state: WorkspaceState
    @Environment(\.viewportSnapshot) private var snapshot

    public init(state: WorkspaceState) { self.state = state }

    public var body: some View {
        ZStack {
            if let snapshot {
                Image(decorative: snapshot, scale: 1).resizable()
            } else {
                MetalViewport(state: state)
            }
            PointerCaptureLayer(handlers: state.viewportHandlers())
        }
    }
}

#if os(macOS)
struct MetalViewport: NSViewRepresentable {
    let state: WorkspaceState
    final class Coordinator { var renderer: ClayRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MTKView { makeView(context.coordinator) }
    func updateNSView(_ v: MTKView, context: Context) {}
}
#else
struct MetalViewport: UIViewRepresentable {
    let state: WorkspaceState
    final class Coordinator { var renderer: ClayRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MTKView { makeView(context.coordinator) }
    func updateUIView(_ v: MTKView, context: Context) {}
}
#endif

extension MetalViewport {
    @MainActor
    func makeView(_ coordinator: Coordinator) -> MTKView {
        let view = MTKView()
        guard let r = ClayRenderer() else { return view }
        view.device = r.device
        view.colorPixelFormat = ClayRenderer.colorFormat
        view.depthStencilPixelFormat = ClayRenderer.depthFormat
        view.sampleCount = ClayRenderer.sampleCount
        view.preferredFramesPerSecond = 120
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        #if os(iOS)
        view.isUserInteractionEnabled = false
        #endif
        r.sceneProvider = { [weak state] in
            MainActor.assumeIsolated { state?.renderScene() ?? RenderScene() }
        }
        r.onFrame = { [weak state] dt in
            MainActor.assumeIsolated { state?.tick(dt) }
        }
        view.delegate = r
        coordinator.renderer = r   // MTKView holds its delegate weakly
        return view
    }
}

// MARK: - Viewport interaction

enum ViewportDrag {
    case pending(start: CGPoint, hit: Vec3?)
    case orbit(last: CGPoint)
    case pan(last: CGPoint)
    case zoom(last: CGPoint)
    case sculpt
}

extension WorkspaceState {

    func viewportHandlers() -> PointerHandlers {
        var h = PointerHandlers()
        h.pointer = { [weak self] e in MainActor.assumeIsolated { self?.viewportPointer(e) } }
        h.scroll = { [weak self] e in MainActor.assumeIsolated { self?.viewportScroll(e) } }
        h.magnify = { [weak self] f, _ in MainActor.assumeIsolated { self?.cameraAnimator.goal = nil; self?.camera.zoom(factor: Float(1 / max(f, 0.01))) } }
        h.twoFingerPan = { [weak self] d in MainActor.assumeIsolated {
            guard let self else { return }
            self.cameraAnimator.goal = nil
            self.camera.pan(dx: d.width, dy: d.height, viewHeight: self.viewportSize.height)
        } }
        h.multiTap = { [weak self] n in MainActor.assumeIsolated { n == 2 ? self?.undo() : self?.redo() } }
        h.pencilDoubleTap = { [weak self] in MainActor.assumeIsolated { self?.pencilDoubleTap() } }
        h.resized = { [weak self] s in MainActor.assumeIsolated {
            guard let self, s.width > 1, s.height > 1, s != self.viewportSize else { return }
            self.viewportSize = s
        } }
        return h
    }

    func ray(at p: CGPoint) -> Ray { camera.ray(at: p, in: viewportSize) }

    func viewportPointer(_ e: PointerEvent) {
        if e.device == .pencil && e.phase == .down { pencilSeen = true }
        if e.phase != .exited { lastViewportPointer = e.location }
        switch e.phase {
        case .moved:
            if modal != nil { updateModal(pointer: e.location) }
            if mode == .sculpt, let m = mesh {
                brushCursor = m.raycast(ray(at: e.location)).map { ($0.position, brush.radius) }
            }
        case .exited:
            brushCursor = nil
        case .down:
            pointerDown(e)
        case .dragged:
            pointerDragged(e)
        case .up, .cancelled:
            pointerUp(e, cancelled: e.phase == .cancelled)
        }
    }

    private func pointerDown(_ e: PointerEvent) {
        if radialMenu != nil { radialMenu = nil; return }
        if modal != nil {
            if e.button == .secondary || e.modifiers.contains(.control) && mode != .sculpt { cancelModal() } else { confirmModal() }
            return
        }
        cameraAnimator.goal = nil
        let p = e.location
        // Navigation buttons / modifiers (Blender: MMB orbit, Shift+MMB pan, Ctrl+MMB zoom; Alt+LMB emulates MMB).
        if e.button == .middle || (e.button == .primary && e.modifiers.contains(.option) && e.device == .mouse) {
            if e.modifiers.contains(.shift) { viewportDrag = .pan(last: p) }
            else if e.modifiers.contains(.control) { viewportDrag = .zoom(last: p) }
            else { viewportDrag = .orbit(last: p) }
            return
        }
        let secondary = e.button == .secondary || (e.modifiers.contains(.control) && mode != .sculpt)
        if secondary {
            if mode == .model || mode == .sculpt, let hit = mesh?.raycast(ray(at: p)) {
                bodySelected = true
                radialMenu = RadialMenuState(location: p, hit: hit.position)
            }
            return
        }
        // Once a Pencil has been used, fingers navigate and the Pencil does the work (Shapr3D style).
        if e.device == .finger && pencilSeen {
            viewportDrag = .orbit(last: p)
            return
        }
        switch mode {
        case .sculpt:
            if sculptBegin(ray: ray(at: p), pressure: e.pressure, invert: e.modifiers.contains(.control), smooth: e.modifiers.contains(.shift)) {
                viewportDrag = .sculpt
            } else {
                viewportDrag = .orbit(last: p)
            }
        default:
            viewportDrag = .pending(start: p, hit: mesh?.raycast(ray(at: p))?.position)
        }
    }

    private func pointerDragged(_ e: PointerEvent) {
        let p = e.location
        switch viewportDrag {
        case .orbit(let last)?:
            camera.orbit(dx: Float(p.x - last.x), dy: Float(p.y - last.y))
            viewportDrag = .orbit(last: p)
        case .pan(let last)?:
            camera.pan(dx: p.x - last.x, dy: p.y - last.y, viewHeight: viewportSize.height)
            viewportDrag = .pan(last: p)
        case .zoom(let last)?:
            camera.zoom(factor: exp(Float(p.y - last.y) * 0.006))
            viewportDrag = .zoom(last: p)
        case .sculpt?:
            sculptDrag(ray: ray(at: p), pressure: e.pressure)
        case .pending(let start, _)?:
            if hypot(p.x - start.x, p.y - start.y) > 4 {
                camera.orbit(dx: Float(p.x - start.x), dy: Float(p.y - start.y))
                viewportDrag = .orbit(last: p)
            }
        case nil:
            if modal != nil { updateModal(pointer: p) }
        }
    }

    private func pointerUp(_ e: PointerEvent, cancelled: Bool) {
        defer { viewportDrag = nil }
        switch viewportDrag {
        case .sculpt?:
            sculptEnd()
        case .pending(let start, let hit)?:
            guard !cancelled else { return }
            tap(at: start, hit: hit, device: e.device)
        default:
            break
        }
    }

    /// A click/tap without dragging.
    private func tap(at p: CGPoint, hit: Vec3?, device: PointerEvent.Device) {
        switch mode {
        case .model:
            if let hit {
                bodySelected = true
                if device != .mouse { radialMenu = RadialMenuState(location: p, hit: hit) }
            } else {
                bodySelected = false
                selectedFeatureID = nil
            }
        case .dimension:
            guard let hit else { pendingMeasure = nil; editingCallout = nil; return }
            if dimensionTool == .measure {
                addMeasurePoint(hit)
            } else if let m = mesh {
                let b = m.bounds
                let t = (hit.y - b.min.y) / max(b.size.y, 1)
                if t < 0.18 { editingCallout = .profile(.baseWidth) }
                else if t > 0.85 { editingCallout = .profile(.rimWidth) }
                else { addMeasurePoint(hit) }
                tutorial?.handle(.tappedBody, in: self)
            }
        default:
            break
        }
    }

    func addMeasurePoint(_ hit: Vec3) {
        // Snap to the nearest vertex so "vertex pair" measurements are exact.
        var p = hit
        if let m = mesh {
            var best = Float.greatestFiniteMagnitude
            for v in m.positions {
                let d = simd_distance_squared(v, hit)
                if d < best { best = d; p = v }
            }
            if best > 4 { p = hit }
        }
        if let a = pendingMeasure {
            measurements.append(Measurement(a: a, b: p))
            pendingMeasure = nil
            hapticTick += 1
        } else {
            pendingMeasure = p
        }
    }

    func viewportScroll(_ e: ScrollEvent) {
        cameraAnimator.goal = nil
        let dx = Float(e.delta.width), dy = Float(e.delta.height)
        if !e.precise {
            // Mouse wheel: dolly.
            camera.zoom(factor: exp(-dy * 0.1))
        } else if e.modifiers.contains(.command) || e.modifiers.contains(.control) {
            camera.zoom(factor: exp(-dy * 0.01))
        } else if e.modifiers.contains(.shift) {
            camera.pan(dx: e.delta.width, dy: e.delta.height, viewHeight: viewportSize.height)
        } else {
            // Trackpad two-finger swipe orbits, as in Blender.
            camera.orbit(dx: dx, dy: dy)
        }
    }

    func pencilDoubleTap() {
        switch mode {
        case .sculpt:
            if brush.kind == .smooth { brush.kind = lastNonSmoothBrush } else { lastNonSmoothBrush = brush.kind; brush.kind = .smooth }
            showToast(brush.kind.title, symbol: brush.kind.symbol)
        case .sketch:
            sketchTool = sketchTool == .eraser ? .pencil : .eraser
            showToast(sketchTool.title, symbol: sketchTool.symbol)
        default:
            break
        }
    }

    var lastNonSmoothBrush: BrushKind {
        get { UserDefaults.standard.string(forKey: "Clay.lastBrush").flatMap(BrushKind.init(rawValue:)) ?? .clay }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "Clay.lastBrush") }
    }
}
