import SwiftUI
import simd

private let axisColors: [Color] = [
    Color(red: 0.90, green: 0.27, blue: 0.24),
    Color(red: 0.36, green: 0.72, blue: 0.27),
    Color(red: 0.22, green: 0.45, blue: 0.92),
]

/// Move arrows, rotation rings and scale handles for the selected body. Dragging a handle runs
/// the same axis-locked modal transform as G/R/S + X/Y/Z on the keyboard.
public struct GizmoOverlayView: View {
    let state: WorkspaceState
    let theme: StudioTheme

    public var body: some View {
        let _ = state.meshRevision
        if state.mode == .model, state.bodySelected || state.modelTool != .select, state.modal == nil || isGizmoModal,
           let m = state.mesh, !m.isEmpty {
            let pivot = m.bounds.center
            let size = state.viewportSize
            let cam = state.camera
            if let c = cam.project(pivot, in: size) {
                let tool: ModelTool = state.modelTool == .select ? .move : state.modelTool
                let len = cam.worldPerPoint(viewHeight: size.height) * 80
                ZStack {
                    Canvas { ctx, _ in
                        for axis in 0..<3 {
                            let dir = ModalTransform.unit(axis)
                            switch tool {
                            case .rotate:
                                let ring = ringPoints(pivot, dir, len * 0.9, cam, size)
                                var p = Path()
                                p.addLines(ring)
                                p.closeSubpath()
                                ctx.stroke(p, with: .color(axisColors[axis].opacity(0.9)), lineWidth: 2.2)
                            default:
                                guard let e = cam.project(pivot + dir * len, in: size) else { continue }
                                var p = Path()
                                p.move(to: c); p.addLine(to: e)
                                ctx.stroke(p, with: .color(axisColors[axis]), lineWidth: 2.4)
                            }
                        }
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(theme.ink.color.opacity(0.7)))
                    }
                    .allowsHitTesting(false)

                    ForEach(0..<3, id: \.self) { axis in
                        if let hp = handlePoint(axis, tool, pivot, len, cam, size) {
                            handle(axis: axis, tool: tool)
                                .position(hp)
                                .gesture(drag(kind: modalKind(tool), constraint: .axis(axis), pivot: pivot))
                        }
                    }
                    Circle().fill(theme.ink.color.opacity(0.001)).frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(theme.ink.color.opacity(0.5), lineWidth: 1.5))
                        .position(c)
                        .gesture(drag(kind: modalKind(tool), constraint: .free, pivot: pivot))
                        .help("Drag to \(tool == .select ? "move" : tool.title.lowercased()) freely")
                }
            }
        }
    }

    private var isGizmoModal: Bool { state.modal?.target == .body }

    private func modalKind(_ t: ModelTool) -> ModalTransform.Kind {
        switch t { case .rotate: .rotate; case .scale: .scale; default: .grab }
    }

    private func ringPoints(_ pivot: Vec3, _ axis: Vec3, _ r: Float, _ cam: OrbitCamera, _ size: CGSize) -> [CGPoint] {
        let u = anyPerpendicular(axis), v = simd_cross(axis, u)
        return (0..<64).compactMap { i in
            let a = Float(i) / 64 * 2 * .pi
            return cam.project(pivot + (u * cos(a) + v * sin(a)) * r, in: size)
        }
    }

    private func handlePoint(_ axis: Int, _ tool: ModelTool, _ pivot: Vec3, _ len: Float, _ cam: OrbitCamera, _ size: CGSize) -> CGPoint? {
        let dir = ModalTransform.unit(axis)
        if tool == .rotate {
            let u = anyPerpendicular(dir), v = simd_cross(dir, u)
            return cam.project(pivot + (u + v).safeNormalized * len * 0.9, in: size)
        }
        return cam.project(pivot + dir * len, in: size)
    }

    @ViewBuilder private func handle(axis: Int, tool: ModelTool) -> some View {
        let color = axisColors[axis]
        Group {
            switch tool {
            case .scale: RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 14, height: 14)
            case .rotate: Circle().fill(color).frame(width: 14, height: 14)
            default: Image(systemName: "arrowtriangle.up.fill").font(.system(size: 14)).foregroundStyle(color)
            }
        }
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
        .help(["X", "Y", "Z"][axis] + " axis")
    }

    private func drag(kind: ModalTransform.Kind, constraint: ModalTransform.Constraint, pivot: Vec3) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("viewport"))
            .onChanged { g in
                if state.modal == nil {
                    var m = ModalTransform(kind: kind, target: .body, pivot: pivot, pointer: g.startLocation)
                    m.constraint = constraint
                    state.modal = m
                }
                state.updateModal(pointer: g.location)
            }
            .onEnded { _ in state.confirmModal() }
    }
}

/// Orientation widget (top right): click an axis bubble to snap to that view, like Blender's.
public struct NavigationGizmoView: View {
    let state: WorkspaceState
    let theme: StudioTheme

    public var body: some View {
        let cam = state.camera
        let r: CGFloat = 30
        let axes: [(Vec3, Int, Bool, ViewPreset)] = [
            (Vec3(1, 0, 0), 0, true, .right), (Vec3(-1, 0, 0), 0, false, .left),
            (Vec3(0, 1, 0), 1, true, .top), (Vec3(0, -1, 0), 1, false, .bottom),
            (Vec3(0, 0, 1), 2, true, .front), (Vec3(0, 0, -1), 2, false, .back),
        ]
        // Far bubbles first so near ones draw on top.
        let sorted = axes.sorted { simd_dot($0.0, cam.forward) > simd_dot($1.0, cam.forward) }
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(theme.panel.color.opacity(0.6)).frame(width: 84, height: 84)
                ForEach(Array(sorted.enumerated()), id: \.offset) { _, item in
                    let (dir, axis, positive, preset) = item
                    let p = CGPoint(x: CGFloat(simd_dot(dir, cam.right)) * r, y: -CGFloat(simd_dot(dir, cam.up)) * r)
                    if positive {
                        Path { path in path.move(to: CGPoint(x: 42, y: 42)); path.addLine(to: CGPoint(x: 42 + p.x, y: 42 + p.y)) }
                            .stroke(axisColors[axis], lineWidth: 2)
                            .frame(width: 84, height: 84)
                            .allowsHitTesting(false)
                    }
                    Button { state.setView(preset) } label: {
                        Text(positive ? ["X", "Y", "Z"][axis] : "")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: positive ? 19 : 14, height: positive ? 19 : 14)
                            .background(Circle().fill(axisColors[axis].opacity(positive ? 1 : 0.45)))
                    }
                    .buttonStyle(.plain)
                    .offset(x: p.x, y: p.y)
                    .help("\(preset.rawValue.capitalized) view")
                }
            }
            .frame(width: 84, height: 84)
            HStack(spacing: 6) {
                ToolButton(symbol: cam.orthographic ? "square" : "cube", label: "Perspective / Orthographic (Numpad 5)",
                           theme: theme, size: 30) { state.toggleOrtho() }
                ToolButton(symbol: "viewfinder", label: "Frame all (Home)", theme: theme, size: 30) { state.frameAll() }
            }
        }
    }
}

/// Shapr3D-style quick-action ring that opens where the body was tapped.
public struct RadialMenuView: View {
    let state: WorkspaceState
    let theme: StudioTheme
    @State private var appeared = false

    public var body: some View {
        if let menu = state.radialMenu {
            let actions = RadialAction.allCases
            ZStack {
                Circle().fill(theme.panel.color.opacity(0.35)).frame(width: 220, height: 220)
                    .scaleEffect(appeared ? 1 : 0.4)
                ForEach(Array(actions.enumerated()), id: \.element) { i, a in
                    let ang = -Double.pi / 2 + Double(i) / Double(actions.count) * 2 * .pi
                    Button { state.perform(a) } label: {
                        VStack(spacing: 2) {
                            Image(systemName: a.symbol).font(.system(size: 16, weight: .semibold))
                            Text(a.title).font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(theme.ink.color)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(theme.panel.color))
                        .overlay(Circle().strokeBorder(theme.panelStroke.color))
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    }
                    .buttonStyle(PressableStyle())
                    .offset(x: appeared ? CGFloat(cos(ang)) * 82 : 0, y: appeared ? CGFloat(sin(ang)) * 82 : 0)
                    .opacity(appeared ? 1 : 0)
                }
                Button { state.radialMenu = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(theme.accent.color))
                        .foregroundStyle(theme.onAccent.color)
                }
                .buttonStyle(PressableStyle())
            }
            .position(menu.location)
            .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { appeared = true } }
            .onDisappear { appeared = false }
        }
    }
}
