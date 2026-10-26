import SwiftUI
import simd

/// The Parchment-style orthographic drawing sheet for one plane: paper, alignment guides carried
/// over from the other view, the tutorial ghost, curves, editable points and dimensions.
public struct OrthoSketchCanvas: View {
    let state: WorkspaceState
    let plane: SketchPlane
    let theme: StudioTheme

    public init(state: WorkspaceState, plane: SketchPlane, theme: StudioTheme) {
        self.state = state; self.plane = plane; self.theme = theme
    }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let t = state.sketchViewTransform(plane)
            let sketch = state.timeline.sketch(plane) ?? Sketch()
            let other = state.timeline.sketch(plane == .front ? .side : .front) ?? Sketch()
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    draw(&ctx, size: size, t: t, sketch: sketch, other: other)
                }
                PointerCaptureLayer(handlers: state.sketchHandlers(plane))
                constraintLabels(sketch: sketch, t: t, size: size)
                planeBadge
                    .padding(12)
                    .allowsHitTesting(false)
            }
            .onAppear {
                state.sketchCanvasSizes[plane] = size
                if state.sketchViews[plane] == nil { state.fitSketchView(plane) }
            }
            .onChange(of: size) { _, s in state.sketchCanvasSizes[plane] = s }
        }
        .clipped()
    }

    private var planeBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: plane == .front ? "square.fill" : "square.lefthalf.filled")
            Text("\(plane.title) · \(plane == .front ? "XY" : "ZY")")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(theme.ink.color.opacity(0.75))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(theme.paper.color.opacity(0.9)))
        .overlay(Capsule().strokeBorder(state.activePlane == plane ? theme.accent.color : theme.panelStroke.color, lineWidth: 1.5))
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, t: SketchViewTransform, sketch: Sketch, other: Sketch) {
        PaperGridPattern.draw(in: &ctx, size: size, transform: t, style: state.document.paper, theme: theme)
        let v: (Vec2) -> CGPoint = { t.toView($0, size: size) }

        // Alignment guides projected from the other orthographic view.
        for g in SilhouetteMatcher.guides(from: other) {
            let y = v(Vec2(0, g.height)).y
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            let major = g.strength == .major
            ctx.stroke(p, with: .color(theme.guideInk.color.opacity(major ? 1 : 0.45)),
                       style: StrokeStyle(lineWidth: major ? 1.2 : 0.8, dash: major ? [8, 5] : [2, 4]))
            if !g.label.isEmpty {
                ctx.draw(Text(g.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.guideInk.color),
                         at: CGPoint(x: size.width - 36, y: y - 8))
            }
        }

        // Tutorial ghost.
        if let ghost = state.tutorial?.ghost(for: plane) {
            let path = bezierPath(ghost, v)
            ctx.stroke(path, with: .color(theme.ghostInk.color), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            ctx.stroke(path, with: .color(theme.accent.color.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
        }

        // Curves (the selected one transformed live during a G/R/S modal).
        let map = state.modalMap2D()
        let selected = state.sketchSelection?.plane == plane ? state.sketchSelection : nil
        for path in sketch.paths {
            var shown = path
            if let map, case .sketchPath(plane, path.id)? = state.modal?.target { shown = path.transformed(map) }
            let isSel = selected?.pathID == path.id
            if !path.closed {
                // Faint mirror: open strokes are half-profiles revolved about the axis.
                let mirrored = shown.transformed { Vec2(-$0.x, $0.y) }
                ctx.stroke(bezierPath(mirrored, v), with: .color(theme.sketchInk.color.opacity(0.18)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4]))
            }
            ctx.stroke(bezierPath(shown, v), with: .color(isSel ? theme.accent.color : theme.sketchInk.color),
                       style: StrokeStyle(lineWidth: isSel ? 2.8 : 2.2, lineCap: .round, lineJoin: .round))
            if state.sketchTool == .edit || state.sketchTool == .dimension || isSel {
                drawAnchors(&ctx, shown, v, showHandles: isSel && state.sketchTool == .edit, selected: isSel ? selected?.anchors ?? [] : [])
            }
        }

        // Pending dimension picks.
        for r in state.pendingDimensionAnchors {
            if let p = state.position(r, in: sketch) {
                let q = v(p)
                ctx.stroke(Path(ellipseIn: CGRect(x: q.x - 8, y: q.y - 8, width: 16, height: 16)), with: .color(theme.accent.color), lineWidth: 2)
            }
        }

        // Live input.
        if state.livePlane == plane {
            if state.liveStroke.count > 1 {
                var p = Path()
                p.addLines(state.liveStroke.map(v))
                ctx.stroke(p, with: .color(theme.sketchInk.color.opacity(0.85)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                if let f = state.liveStroke.first, let l = state.liveStroke.last, simd_distance(f, l) < Float(18 / t.scale) {
                    let q = v(f)
                    ctx.stroke(Path(ellipseIn: CGRect(x: q.x - 9, y: q.y - 9, width: 18, height: 18)), with: .color(theme.accent.color), lineWidth: 2)
                }
            }
            if !state.livePolyline.isEmpty {
                var p = Path()
                p.addLines(state.livePolyline.map(v))
                if let h = state.sketchHover { p.addLine(to: v(h)) }
                ctx.stroke(p, with: .color(theme.accent.color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                for q in state.livePolyline.map(v) {
                    ctx.fill(Path(ellipseIn: CGRect(x: q.x - 3.5, y: q.y - 3.5, width: 7, height: 7)), with: .color(theme.accent.color))
                }
            }
            if let s = state.liveShape {
                let shape: SketchPath = state.sketchTool == .circle
                    ? .circle(center: s.start, radius: max(simd_distance(s.start, s.end), 0.01))
                    : .rectangle(s.start, s.end)
                ctx.stroke(bezierPath(shape, v), with: .color(theme.accent.color), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                let label = state.sketchTool == .circle
                    ? "R \(state.units.format(simd_distance(s.start, s.end)))"
                    : "\(state.units.format(abs(s.end.x - s.start.x))) × \(state.units.format(abs(s.end.y - s.start.y)))"
                ctx.draw(Text(label).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(theme.accent.color),
                         at: CGPoint(x: v(s.end).x + 10, y: v(s.end).y - 12), anchor: .leading)
            }
            if let h = state.sketchHover, state.sketchTool != .edit {
                ctx.draw(Text(String(format: "%.1f, %.1f", h.x, h.y)).font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(theme.secondaryInk.color), at: CGPoint(x: size.width - 12, y: size.height - 12), anchor: .bottomTrailing)
            }
        }
    }

    private func bezierPath(_ s: SketchPath, _ v: (Vec2) -> CGPoint) -> Path {
        var p = Path()
        guard let first = s.anchors.first else { return p }
        p.move(to: v(first.position))
        for seg in s.segments {
            p.addCurve(to: v(seg.p3), control1: v(seg.p1), control2: v(seg.p2))
        }
        if s.closed { p.closeSubpath() }
        return p
    }

    private func drawAnchors(_ ctx: inout GraphicsContext, _ path: SketchPath, _ v: (Vec2) -> CGPoint, showHandles: Bool, selected: [Int]) {
        for (i, a) in path.anchors.enumerated() {
            let q = v(a.position)
            if showHandles {
                for h in [a.inHandle, a.outHandle] where h != .zero {
                    let hq = v(a.position + h)
                    var l = Path(); l.move(to: q); l.addLine(to: hq)
                    ctx.stroke(l, with: .color(theme.accent.color.opacity(0.6)), lineWidth: 1)
                    ctx.fill(Path(ellipseIn: CGRect(x: hq.x - 3.5, y: hq.y - 3.5, width: 7, height: 7)), with: .color(theme.accent.color))
                }
            }
            let sel = selected.contains(i)
            let r: CGFloat = sel ? 5.5 : 4
            let rect = CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)
            let shape = a.isCorner ? Path(rect) : Path(ellipseIn: rect)
            ctx.fill(shape, with: .color(sel ? theme.accent.color : theme.paper.color))
            ctx.stroke(shape, with: .color(sel ? theme.accent.color : theme.sketchInk.color), lineWidth: 1.4)
        }
    }

    // MARK: Constraint labels

    @ViewBuilder
    private func constraintLabels(sketch: Sketch, t: SketchViewTransform, size: CGSize) -> some View {
        let items: [(Int, SketchConstraint, CGPoint)] = sketch.constraints.enumerated().compactMap { i, c in
            guard let p = labelPoint(c, sketch) else { return nil }
            return (i, c, t.toView(p, size: size))
        }
        ForEach(items, id: \.0) { item in
            let (i, c, q) = item
            let id = CalloutID.sketchConstraint(plane, i)
            Group {
                if let v = c.value {
                    Button { state.editingCallout = id } label: {
                        Text(isAngle(c) ? String(format: "%.1f°", v) : state.units.format(v))
                            .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(theme.paper.color))
                            .overlay(Capsule().strokeBorder(theme.accent.color, lineWidth: state.editingCallout == id ? 2 : 1))
                            .foregroundStyle(theme.ink.color)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: c.symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.onAccent.color)
                        .frame(width: 17, height: 17)
                        .background(Circle().fill(theme.guideInk.color))
                        .help(c.title)
                }
            }
            .contextMenu { Button("Delete \(c.title)", role: .destructive) { state.removeConstraint(plane: plane, at: i) } }
            .position(q)
        }
    }

    private func isAngle(_ c: SketchConstraint) -> Bool { if case .angle = c { return true }; return false }

    private func labelPoint(_ c: SketchConstraint, _ s: Sketch) -> Vec2? {
        let refs = c.anchorRefs
        if refs.count >= 2 {
            let pts = refs.compactMap { state.position($0, in: s) }
            guard pts.count == refs.count else { return nil }
            let mid = pts.reduce(.zero, +) / Float(pts.count)
            return mid + ((pts[1] - pts[0]).safeNormalized.perpendicular * 6)
        }
        if let r = refs.first { return state.position(r, in: s).map { $0 + Vec2(6, 6) } }
        if let pid = c.circlePaths.first, let i = s.pathIndex(pid) {
            let p = s.paths[i]
            return p.centroid
        }
        return nil
    }
}
