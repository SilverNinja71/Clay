import SwiftUI
import simd

// MARK: - Model

public enum CalloutID: Hashable, Sendable {
    case profile(ProfileDimension)
    case feature(UUID)
    case measurement(UUID)
    case sketchConstraint(SketchPlane, Int)
}

/// One CAD dimension shown in the viewport: a measured value between two world points
/// (`leader` callouts point at a single spot instead).
public struct DimensionCallout: Identifiable, Sendable {
    public var id: CalloutID
    public var title: String
    public var value: Float
    public var isAngle = false
    public var a: Vec3
    public var b: Vec3
    public var leader = false
    public var editable = true
    public var driving = true
}

extension WorkspaceState {

    /// Dimensions to show for the current mode.
    public func callouts() -> [DimensionCallout] {
        var out: [DimensionCallout] = []
        guard let front = timeline.sketch(.front) else { return out }
        let side = timeline.sketch(.side).flatMap { $0.isEmpty ? nil : $0 }
        if mode == .dimension && timeline.loftIndex != nil {
            for d in ProfileDimension.allCases {
                if d == .depth && side == nil { continue }
                guard let v = ProfileDimensionSolver.measure(d, front: front, side: side),
                      let (a, b) = ProfileDimensionSolver.anchors(d, front: front, side: side) else { continue }
                out.append(DimensionCallout(id: .profile(d), title: d.title, value: v, a: a, b: b))
            }
        }
        if let m = mesh, !m.isEmpty {
            for f in timeline.features.prefix(timeline.activeCount) where !f.suppressed {
                guard mode == .dimension || (mode == .model && f.id == selectedFeatureID) else { continue }
                if let c = featureCallout(f, m) { out.append(c) }
            }
        }
        if mode == .dimension {
            for m in measurements {
                out.append(DimensionCallout(id: .measurement(m.id), title: "Measure", value: simd_distance(m.a, m.b),
                                            a: m.a, b: m.b, editable: false, driving: false))
            }
        }
        return out
    }

    private func featureCallout(_ f: Feature, _ m: ClayMesh) -> DimensionCallout? {
        let b = m.bounds
        let c = b.center
        switch f.kind {
        case .edgeTreatment(let e):
            let y = e.edge == .top ? b.max.y : b.min.y
            let p = Vec3(b.max.x - e.size * 0.5, y, c.z)
            return DimensionCallout(id: .feature(f.id), title: f.name, value: e.size, a: p, b: p, leader: true)
        case .shell(let s):
            let p = Vec3(b.max.x, b.max.y, c.z)
            return DimensionCallout(id: .feature(f.id), title: "\(f.name) wall", value: s.thickness, a: p, b: p, leader: true)
        case .offset(let d):
            let p = Vec3(b.max.x, c.y, c.z)
            return DimensionCallout(id: .feature(f.id), title: f.name, value: d, a: p, b: p, leader: true)
        case .split(let s):
            return DimensionCallout(id: .feature(f.id), title: "\(f.name) height", value: s.height,
                                    a: Vec3(b.min.x - 12, s.height, c.z), b: Vec3(b.max.x + 12, s.height, c.z))
        case .extrude(let p):
            guard let si = timeline.index(of: p.sketch), let sf = timeline.features[si].sketch,
                  let sb = sf.sketch.bounds else { return nil }
            let mid = (sb.min + sb.max) / 2
            let d0: Float = p.symmetric ? -p.depth / 2 : 0
            let a = sf.plane.worldPoint(Vec2(sb.max.x + 8, mid.y), offset: d0)
            let e = sf.plane.worldPoint(Vec2(sb.max.x + 8, mid.y), offset: d0 + p.depth)
            return DimensionCallout(id: .feature(f.id), title: "\(f.name) depth", value: p.depth, a: a, b: e)
        case .remesh(let r):
            let p = Vec3(b.min.x, b.max.y, c.z)
            return DimensionCallout(id: .feature(f.id), title: "Voxel size", value: r.voxelSize, a: p, b: p, leader: true)
        default:
            return nil
        }
    }

    public func calloutValue(_ id: CalloutID) -> Float? {
        switch id {
        case .profile(let d):
            guard let front = timeline.sketch(.front) else { return nil }
            return ProfileDimensionSolver.measure(d, front: front, side: timeline.sketch(.side).flatMap { $0.isEmpty ? nil : $0 })
        case .feature(let fid):
            guard let f = feature(fid) else { return nil }
            switch f.kind {
            case .edgeTreatment(let e): return e.size
            case .shell(let s): return s.thickness
            case .offset(let d): return d
            case .split(let s): return s.height
            case .extrude(let p): return p.depth
            case .remesh(let r): return r.voxelSize
            default: return nil
            }
        case .measurement(let mid):
            return measurements.first { $0.id == mid }.map { simd_distance($0.a, $0.b) }
        case .sketchConstraint(let plane, let i):
            guard let s = timeline.sketch(plane), i < s.constraints.count else { return nil }
            return s.constraints[i].value
        }
    }

    public func calloutTitle(_ id: CalloutID) -> String {
        switch id {
        case .profile(let d): d.title
        case .feature(let fid): feature(fid)?.name ?? "Feature"
        case .measurement: "Measure"
        case .sketchConstraint(let plane, let i): timeline.sketch(plane).flatMap { i < $0.constraints.count ? $0.constraints[i].title : nil } ?? "Dimension"
        }
    }

    public func calloutIsAngle(_ id: CalloutID) -> Bool {
        if case .sketchConstraint(let plane, let i) = id, let s = timeline.sketch(plane), i < s.constraints.count,
           case .angle = s.constraints[i] { return true }
        return false
    }

    /// Drives a dimension to `value` (mm or degrees). `live` = part of a scrub gesture.
    public func setCallout(_ id: CalloutID, value v: Float, live: Bool = false) {
        switch id {
        case .profile(let d):
            guard var front = timeline.sketch(.front) else { return }
            var side = timeline.sketch(.side).flatMap { $0.isEmpty ? nil : $0 }
            guard ProfileDimensionSolver.apply(d, target: v, front: &front, side: &side) else {
                showToast("That value isn't possible", symbol: "exclamationmark.triangle"); return
            }
            let change: (inout Timeline) -> Void = { tl in
                tl.editSketch(.front) { $0 = front }
                if let side { tl.editSketch(.side) { $0 = side } }
            }
            if live { liveChange(change) } else { commit(change) }
            if !live { tutorial?.handle(.dimensionChanged(d, v), in: self) }
        case .feature(let fid):
            let value = max(v, 0.01)
            editFeature(fid, live: live) { kind in
                switch kind {
                case .edgeTreatment(var e): e.size = value; kind = .edgeTreatment(e)
                case .shell(var s): s.thickness = value; kind = .shell(s)
                case .offset: kind = .offset(v)
                case .split(var s): s.height = v; kind = .split(s)
                case .extrude(var p): p.depth = value; kind = .extrude(p)
                case .remesh(var r): r.voxelSize = max(value, 0.3); kind = .remesh(r)
                default: break
                }
            }
        case .measurement:
            break
        case .sketchConstraint(let plane, let i):
            let change: (inout Timeline) -> Void = { tl in tl.editSketch(plane) { s in
                guard i < s.constraints.count else { return }
                s.constraints[i] = s.constraints[i].withValue(v)
                ConstraintSolver.solve(&s)
            } }
            if live { liveChange(change) } else { commit(change) }
        }
        if !live { hapticTick += 1 }
    }
}

// MARK: - Overlay

/// Floating CAD dimensions: extension lines, arrows and a tappable value pill per callout.
public struct DimensionCalloutLayer: View {
    let state: WorkspaceState
    let theme: StudioTheme

    public var body: some View {
        let _ = state.meshRevision
        let size = state.viewportSize
        let cam = state.camera
        let items: [(DimensionCallout, CGPoint, CGPoint)] = state.callouts().compactMap { c in
            guard let a = cam.project(c.a, in: size), let b = cam.project(c.b, in: size) else { return nil }
            return (c, a, b)
        }
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for (c, a, b) in items {
                    let color = (c.driving ? theme.accent : theme.guideInk).color
                    if c.leader {
                        var p = Path()
                        p.move(to: a)
                        p.addLine(to: CGPoint(x: a.x + 34, y: a.y - 34))
                        p.addLine(to: CGPoint(x: a.x + 54, y: a.y - 34))
                        ctx.stroke(p, with: .color(color), lineWidth: 1.2)
                        ctx.fill(Path(ellipseIn: CGRect(x: a.x - 3, y: a.y - 3, width: 6, height: 6)), with: .color(color))
                    } else {
                        var p = Path()
                        p.move(to: a); p.addLine(to: b)
                        ctx.stroke(p, with: .color(color), lineWidth: 1.4)
                        for (tip, from) in [(a, b), (b, a)] { ctx.fill(arrowHead(tip: tip, from: from), with: .color(color)) }
                        for q in [a, b] {
                            var tick = Path()
                            let n = perpendicular(a, b, 7)
                            tick.move(to: CGPoint(x: q.x - n.x, y: q.y - n.y)); tick.addLine(to: CGPoint(x: q.x + n.x, y: q.y + n.y))
                            ctx.stroke(tick, with: .color(color.opacity(0.8)), lineWidth: 1)
                        }
                    }
                }
                if let p = state.pendingMeasure, let q = cam.project(p, in: size) {
                    ctx.fill(Path(ellipseIn: CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10)), with: .color(theme.accent.color))
                }
            }
            .allowsHitTesting(false)

            let spots = labelPositions(items)
            ForEach(Array(items.enumerated()), id: \.element.0.id) { i, item in
                CalloutPill(state: state, callout: item.0, theme: theme)
                    .fixedSize()
                    .position(spots[i])
            }
        }
    }

    /// Label centres, nudged apart vertically so pills never overlap.
    private func labelPositions(_ items: [(DimensionCallout, CGPoint, CGPoint)]) -> [CGPoint] {
        var p: [CGPoint] = items.map { c, a, b in
            c.leader ? CGPoint(x: a.x + 94, y: a.y - 34) : CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        let w: CGFloat = 150, h: CGFloat = 32
        for _ in 0..<8 {
            var moved = false
            for i in p.indices {
                for j in 0..<i where abs(p[i].x - p[j].x) < w && abs(p[i].y - p[j].y) < h {
                    let push = (h - abs(p[i].y - p[j].y)) / 2 + 1
                    let dir: CGFloat = p[i].y >= p[j].y ? 1 : -1
                    p[i].y += push * dir
                    p[j].y -= push * dir
                    moved = true
                }
            }
            if !moved { break }
        }
        return p
    }

    private func perpendicular(_ a: CGPoint, _ b: CGPoint, _ len: CGFloat) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let l = max(hypot(dx, dy), 0.001)
        return CGPoint(x: -dy / l * len, y: dx / l * len)
    }

    private func arrowHead(tip: CGPoint, from: CGPoint) -> Path {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let l = max(hypot(dx, dy), 0.001)
        let ux = dx / l, uy = dy / l
        var p = Path()
        p.move(to: tip)
        p.addLine(to: CGPoint(x: tip.x - ux * 9 - uy * 4, y: tip.y - uy * 9 + ux * 4))
        p.addLine(to: CGPoint(x: tip.x - ux * 9 + uy * 4, y: tip.y - uy * 9 - ux * 4))
        p.closeSubpath()
        return p
    }
}

/// The value label. Tap to type an exact value; drag sideways to scrub.
struct CalloutPill: View {
    let state: WorkspaceState
    let callout: DimensionCallout
    let theme: StudioTheme
    @State private var scrubStart: Float?
    @State private var pulse = false

    var body: some View {
        let editing = state.editingCallout == callout.id
        let highlight = state.tutorial?.highlightedCallout == callout.id
        HStack(spacing: 5) {
            if !callout.title.isEmpty {
                Text(callout.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.secondaryInk.color)
            }
            Text(callout.isAngle ? String(format: "%.1f°", callout.value) : state.units.format(callout.value))
                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(theme.ink.color)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(theme.panel.color.opacity(0.96)))
        .overlay(Capsule().strokeBorder((editing || highlight ? theme.accent : theme.panelStroke).color, lineWidth: editing || highlight ? 2 : 1))
        .scaleEffect(highlight && pulse ? 1.12 : 1)
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .contentShape(Capsule())
        .onTapGesture { if callout.editable { state.editingCallout = callout.id } }
        .gesture(DragGesture(minimumDistance: 6).onChanged { g in
            guard callout.editable else { return }
            if scrubStart == nil { scrubStart = callout.value; state.pushUndo() }
            let step: Float = callout.isAngle ? 0.5 : 0.25
            state.setCallout(callout.id, value: max(0.1, (scrubStart ?? 0) + Float(g.translation.width) * step), live: true)
        }.onEnded { _ in
            if scrubStart != nil { state.hapticTick += 1 }
            scrubStart = nil
        })
        .help(callout.editable ? "Tap to type a value, drag to scrub" : "Reference dimension")
        .onAppear {
            guard highlight else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// Numeric entry for the selected dimension: accepts expressions like `65`, `6.5 cm`, `50 + 15`.
public struct DimensionEditor: View {
    let state: WorkspaceState
    let theme: StudioTheme
    let id: CalloutID
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    public var body: some View {
        let isAngle = state.calloutIsAngle(id)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "ruler").foregroundStyle(theme.accent.color)
                Text(state.calloutTitle(id)).font(.headline).foregroundStyle(theme.ink.color)
                Spacer()
                Button { state.editingCallout = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(theme.secondaryInk.color)
            }
            HStack(spacing: 8) {
                stepButton("minus", -1, isAngle)
                TextField("Value", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit(apply)
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(theme.canvas.color.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(invalid ? Color.red : theme.panelStroke.color))
                Text(isAngle ? "°" : state.units.symbol).foregroundStyle(theme.secondaryInk.color)
                stepButton("plus", 1, isAngle)
            }
            HStack {
                Picker("Units", selection: Binding(get: { state.units }, set: { state.units = $0; load() })) {
                    ForEach(LengthUnit.allCases) { Text($0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(isAngle)
                Button("Apply", action: apply)
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent.color)
            }
            Text("Try 65, 6.5 cm or 50 + 15").font(.caption).foregroundStyle(theme.secondaryInk.color)
        }
        .padding(14)
        .frame(width: 300)
        .floatingPanel(theme)
        .onAppear { load(); focused = true }
        .onChange(of: id) { load() }
    }

    private func stepButton(_ symbol: String, _ dir: Float, _ isAngle: Bool) -> some View {
        Button {
            guard let v = state.calloutValue(id) else { return }
            let step: Float = isAngle ? 1 : state.units.millimetres * (state.units == .mm ? 1 : 0.1)
            state.setCallout(id, value: max(0.1, v + dir * step))
            load()
        } label: {
            Image(systemName: symbol).frame(width: 30, height: 30)
                .background(Circle().fill(theme.canvas.color.opacity(0.6)))
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(theme.ink.color)
    }

    private func load() {
        guard let v = state.calloutValue(id) else { return }
        text = state.calloutIsAngle(id) ? String(format: "%.1f", v) : state.units.format(v, withSymbol: false)
        invalid = false
    }

    private func apply() {
        let isAngle = state.calloutIsAngle(id)
        let parsed: Float? = isAngle ? Float(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "°", with: ""))
                                     : UnitExpression.evaluate(text, defaultUnit: state.units)
        guard let v = parsed, v > 0 || { if case .feature = id { return true }; return false }() else { invalid = true; return }
        state.setCallout(id, value: v)
        state.editingCallout = nil
    }
}
