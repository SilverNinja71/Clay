import SwiftUI
import simd

/// Right-hand panel: settings for the current mode and the selected timeline step.
struct InspectorPanel: View {
    @Bindable var state: WorkspaceState
    let theme: StudioTheme

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                switch state.mode {
                case .sketch: sketchInspector
                case .model: modelInspector
                case .sculpt: sculptInspector
                case .dimension: dimensionInspector
                }
            }
            .padding(14)
        }
        .frame(maxHeight: 580)
        .fixedSize(horizontal: false, vertical: true)
        .floatingPanel(theme, radius: 20)
        .foregroundStyle(theme.ink.color)
        .tint(theme.accent.color)
    }

    // MARK: Sketch

    @ViewBuilder private var sketchInspector: some View {
        SketchPlanesSection(state: state, theme: theme)
        section("Paper", symbol: "doc") {
            ClaySegmented(PaperStyle.allCases.map { .init($0, nil, symbol: $0.symbol) },
                          selection: Binding(get: { state.document.paper }, set: { state.document.paper = $0; state.scheduleSave() }), theme: theme)
            unitPicker
            Button { state.fitSketchView(state.activePlaneID) } label: { Label("Fit sheet to drawing", systemImage: "viewfinder") }
                .buttonStyle(ClayPillButtonStyle(theme: theme))
        }
        if let front = state.timeline.sketch(.front), let side = state.timeline.sketch(.side),
           let off = SilhouetteMatcher.heightMismatch(front: front, side: side), off > 1.5 {
            section("Alignment", symbol: "arrow.up.and.down") {
                note("Side profile is \(state.units.format(off)) out of line with the front.")
                Button { state.matchSideHeight() } label: { Label("Match side height to front", systemImage: "arrow.up.and.down") }
                    .buttonStyle(ClayPillButtonStyle(theme: theme, prominent: true))
            }
        }
        if let sel = state.sketchSelection, let path = state.sketchPath(sel) {
            section("Selected curve", symbol: "scribble") {
                infoRow("Type", path.closed ? "Closed \(path.kind.rawValue)" : "Open \(path.kind.rawValue)")
                infoRow("Points", "\(path.anchors.count)")
                infoRow("Length", state.units.format(path.length))
                if !path.closed && state.timeline.plane(sel.planeID)?.standard != nil {
                    note("Open curves are half-profiles: they mirror around the dashed axis.")
                }
                HStack(spacing: 6) {
                    if path.closed { Button { state.extrude() } label: { Label("Extrude", systemImage: "square.stack.3d.up") } }
                    Button { state.duplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button(role: .destructive) { state.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                }
                .buttonStyle(ClayPillButtonStyle(theme: theme))
            }
            let options = state.availableConstraints()
            section("Constraints", symbol: "lock") {
                if options.isEmpty {
                    note("With Edit points (V), shift-click 1–4 points to constrain them.")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 6)], spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, c in
                        Button { state.addConstraint(c, planeID: sel.planeID, edit: c.value != nil) } label: {
                            Label(c.title, systemImage: c.symbol).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ClayPillButtonStyle(theme: theme))
                    }
                }
            }
        }
        if let id = state.activePlaneID, let s = state.timeline.plane(id)?.sketch, !s.constraints.isEmpty {
            section("Constraints on this plane", symbol: "lock.fill") {
                ForEach(Array(s.constraints.enumerated()), id: \.offset) { i, c in
                    HStack {
                        Image(systemName: c.symbol).frame(width: 18).foregroundStyle(theme.accent.color)
                        Text(c.title).font(.system(size: 12))
                        Spacer()
                        if let v = c.value { Text(isAngle(c) ? String(format: "%.1f°", v) : state.units.format(v)).font(.system(size: 12).monospacedDigit()) }
                        Button { state.removeConstraint(planeID: id, at: i) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(theme.secondaryInk.color)
                    }
                }
            }
        }
    }

    // MARK: Model

    @ViewBuilder private var modelInspector: some View {
        if let f = state.feature(state.selectedFeatureID) {
            section(f.name, symbol: f.kind.symbol) {
                if let msg = state.statuses[f.id]?.message {
                    Label(msg, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                featureEditor(f)
            }
        }
        SketchPlanesSection(state: state, theme: theme, compact: true)
        section("Quick actions", symbol: "bolt") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(RadialAction.allCases.filter { $0 != .dimension }) { a in
                    Button { state.perform(a) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: a.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent.color)
                            Text(a.title).font(.system(size: 10, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.canvas.color.opacity(theme.isDark ? 0.5 : 0.7)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.panelStroke.color))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            HStack(spacing: 6) {
                Button { state.remesh() } label: { Label("Remesh", systemImage: "circle.hexagongrid") }
                Button { state.subdivide() } label: { Label("Subdivide", systemImage: "square.grid.3x3") }
            }
            .buttonStyle(ClayPillButtonStyle(theme: theme))
        }
        if state.stats.triangles > 0 {
            section("Body", symbol: "cube") {
                infoRow("Size", "\(fmt(state.stats.size.x)) × \(fmt(state.stats.size.y)) × \(fmt(state.stats.size.z)) \(state.units.symbol)")
                infoRow("Volume", String(format: "%.1f cm³", state.stats.volume / 1000))
                infoRow("Triangles", state.stats.triangles.formatted())
                HStack {
                    Text("Watertight").font(.system(size: 12)).foregroundStyle(theme.secondaryInk.color)
                    Spacer()
                    if state.stats.watertight { PrintReadyBadge(theme: theme) } else { Text("No").font(.system(size: 12, weight: .medium)) }
                }
            }
        }
    }

    @ViewBuilder private func featureEditor(_ f: Feature) -> some View {
        switch f.kind {
        case .sketch(let s):
            Button { state.openFeature(f.id) } label: { Label("Edit \(s.plane.name.lowercased())", systemImage: "pencil") }
                .buttonStyle(ClayPillButtonStyle(theme: theme, prominent: true))
        case .loft:
            intSlider("Rings", f.id, 40...300) { if case .loft(let p) = $0 { return p.rings }; return nil } set: { k, v in if case .loft(var p) = k { p.rings = v; k = .loft(p) } }
            intSlider("Segments", f.id, 16...256) { if case .loft(let p) = $0 { return p.segments }; return nil } set: { k, v in if case .loft(var p) = k { p.segments = v; k = .loft(p) } }
            slider("Squareness", f.id, 0...1, format: { String(format: "%.2f", $0) }) { if case .loft(let p) = $0 { return p.squareness }; return nil } set: { k, v in if case .loft(var p) = k { p.squareness = v; k = .loft(p) } }
            note("Changing rings or segments changes the mesh topology, which resets later sculpt layers.")
        case .sectionLoft(let p):
            infoRow("Sections", "\(p.planes.count)")
            intSlider("Smoothness", f.id, 2...40) { if case .sectionLoft(let x) = $0 { return x.spanRings }; return nil } set: { k, v in if case .sectionLoft(var x) = k { x.spanRings = v; k = .sectionLoft(x) } }
            if p.planes.count == 1 {
                slider("Puff", f.id, 0.1...1.5, format: { String(format: "%.2f", $0) }) { if case .sectionLoft(let x) = $0 { return x.inflate }; return nil } set: { k, v in if case .sectionLoft(var x) = k { x.inflate = v; k = .sectionLoft(x) } }
            }
            Button { state.formClay() } label: { Label("Re-form with current planes", systemImage: "arrow.triangle.2.circlepath") }
                .buttonStyle(ClayPillButtonStyle(theme: theme))
        case .edgeTreatment(let e):
            ClaySegmented(EdgeTreatment.Style.allCases.map { .init($0, $0.rawValue.capitalized) },
                          selection: Binding(get: { e.style }, set: { v in state.editFeature(f.id) { if case .edgeTreatment(var x) = $0 { x.style = v; $0 = .edgeTreatment(x) } } }), theme: theme)
            ClaySegmented(EdgeTreatment.Edge.allCases.map { .init($0, $0.rawValue.capitalized) },
                          selection: Binding(get: { e.edge }, set: { v in state.editFeature(f.id) { if case .edgeTreatment(var x) = $0 { x.edge = v; $0 = .edgeTreatment(x) } } }), theme: theme)
            slider("Size", f.id, 0.2...20, format: { state.units.format($0) }) { if case .edgeTreatment(let x) = $0 { return x.size }; return nil } set: { k, v in if case .edgeTreatment(var x) = k { x.size = v; k = .edgeTreatment(x) } }
        case .shell(let s):
            slider("Wall", f.id, 0.4...15, format: { state.units.format($0) }) { if case .shell(let x) = $0 { return x.thickness }; return nil } set: { k, v in if case .shell(var x) = k { x.thickness = v; k = .shell(x) } }
            ClayToggleChip("Open top", symbol: "cup.and.saucer", isOn: Binding(get: { s.openTop }, set: { v in state.editFeature(f.id) { if case .shell(var x) = $0 { x.openTop = v; $0 = .shell(x) } } }), theme: theme)
        case .offset:
            slider("Distance", f.id, -10...10, format: { state.units.format($0) }) { if case .offset(let d) = $0 { return d }; return nil } set: { k, v in k = .offset(v) }
        case .split(let sp):
            let b = state.evaluator.meshBefore(state.timeline.index(of: f.id) ?? 0)?.bounds ?? state.sceneBounds
            slider("Height", f.id, b.min.y...max(b.max.y, b.min.y + 1), format: { state.units.format($0) }) { if case .split(let x) = $0 { return x.height }; return nil } set: { k, v in if case .split(var x) = k { x.height = v; k = .split(x) } }
            ClaySegmented([.init(true, "Keep below", symbol: "arrow.down"), .init(false, "Keep above", symbol: "arrow.up")],
                          selection: Binding(get: { sp.keepBelow }, set: { v in state.editFeature(f.id) { if case .split(var x) = $0 { x.keepBelow = v; $0 = .split(x) } } }), theme: theme)
        case .extrude(let p):
            slider("Depth", f.id, 0.5...200, format: { state.units.format($0) }) { if case .extrude(let x) = $0 { return x.depth }; return nil } set: { k, v in if case .extrude(var x) = k { x.depth = v; k = .extrude(x) } }
            ClayToggleChip("Symmetric", symbol: "arrow.left.and.right", isOn: Binding(get: { p.symmetric }, set: { v in state.editFeature(f.id) { if case .extrude(var x) = $0 { x.symmetric = v; $0 = .extrude(x) } } }), theme: theme)
        case .remesh:
            slider("Voxel size", f.id, 0.4...4, format: { state.units.format($0) }) { if case .remesh(let x) = $0 { return x.voxelSize }; return nil } set: { k, v in if case .remesh(var x) = k { x.voxelSize = v; k = .remesh(x) } }
        case .sculpt(let layer):
            infoRow("Vertices moved", "\(layer.displacements.filter { $0 != .zero }.count.formatted())")
            Button(role: .destructive) {
                state.editFeature(f.id) { $0 = .sculpt(SculptLayer(vertexCount: layer.vertexCount)) }
            } label: { Label("Clear sculpt layer", systemImage: "eraser") }
                .buttonStyle(ClayPillButtonStyle(theme: theme))
        case .transform(let t), .duplicate(let t):
            infoRow("Move", "\(fmt(t.translation.x)), \(fmt(t.translation.y)), \(fmt(t.translation.z))")
            infoRow("Rotate", String(format: "%.1f°", t.rotationDegrees))
            infoRow("Scale", "\(String(format: "%.2f", t.scale.x)) × \(String(format: "%.2f", t.scale.y)) × \(String(format: "%.2f", t.scale.z))")
        case .subdivide:
            note("Each triangle split into four.")
        }
    }

    // MARK: Sculpt

    @ViewBuilder private var sculptInspector: some View {
        let b = state.brush.kind
        HStack(spacing: 12) {
            Image(systemName: b.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.onAccent.color)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(theme.accent.color))
            VStack(alignment: .leading, spacing: 2) {
                Text(b.title).font(.system(size: 17, weight: .bold))
                Text(state.brush.invert ? "\(b.inverseTitle) mode" : "Hold Ctrl to \(b.inverseTitle.lowercased())")
                    .font(.system(size: 11)).foregroundStyle(theme.secondaryInk.color)
            }
            Spacer()
            Text(b.hotkey)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.canvas.color.opacity(0.8)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.panelStroke.color))
                .help("Keyboard shortcut")
        }
        section("Brush", symbol: "paintbrush.pointed") {
            ClaySlider("Radius", value: $state.brush.radius, in: 1...40, theme: theme, format: { state.units.format($0) })
            ClaySlider("Strength", value: $state.brush.strength, in: 0.02...1, theme: theme, format: { String(format: "%.0f%%", $0 * 100) })
            ClaySlider("Spacing", value: $state.brush.spacing, in: 0.04...0.5, theme: theme, format: { String(format: "%.0f%%", $0 * 100) })
        }
        section("Falloff", symbol: "waveform.path") {
            FalloffPicker(selection: $state.brush.falloff, theme: theme)
        }
        section("Options", symbol: "slider.horizontal.3") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                ClayToggleChip(b.inverseTitle, symbol: "minus.circle", isOn: $state.brush.invert, theme: theme)
                ClayToggleChip("X symmetry", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", isOn: $state.brush.symmetryX, theme: theme)
                ClayToggleChip("Pressure size", symbol: "circle.dotted", isOn: $state.brush.pressureRadius, theme: theme)
                ClayToggleChip("Pressure force", symbol: "hand.tap", isOn: $state.brush.pressureStrength, theme: theme)
            }
        }
        section("Topology", symbol: "circle.hexagongrid") {
            note("Grab and Inflate stretch triangles; remesh to make them even again.")
            HStack(spacing: 6) {
                Button { state.remesh() } label: { Label("Voxel remesh", systemImage: "circle.hexagongrid") }
                Button { state.subdivide() } label: { Label("Subdivide", systemImage: "square.grid.3x3") }
            }
            .buttonStyle(ClayPillButtonStyle(theme: theme))
            infoRow("Triangles", state.stats.triangles.formatted())
        }
    }

    // MARK: Dimension

    @ViewBuilder private var dimensionInspector: some View {
        section("Units", symbol: "ruler") { unitPicker }
        let items = state.callouts()
        section("Dimensions", symbol: "ruler.fill") {
            if items.isEmpty {
                note("Generate 3D Clay to see the model's driving dimensions.")
            }
            ForEach(items) { c in
                Button { if c.editable { state.editingCallout = c.id } } label: {
                    HStack {
                        Image(systemName: c.driving ? "ruler" : "ruler.fill").foregroundStyle(c.driving ? theme.accent.color : theme.guideInk.color)
                        Text(c.title).font(.system(size: 12))
                        Spacer()
                        Text(state.units.format(c.value)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(theme.canvas.color.opacity(0.7)))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        section("How it works", symbol: "questionmark.circle") {
            note("Driving dimensions edit the sketches and the timeline rebuilds everything after them — sculpting included. Tap the base or rim of the model, or use Measure (M) for reference distances.")
        }
    }

    // MARK: Pieces

    private var unitPicker: some View {
        ClaySegmented(LengthUnit.allCases.map { .init($0, $0.symbol) },
                      selection: Binding(get: { state.units }, set: { state.units = $0 }), theme: theme)
    }

    private func section<C: View>(_ title: String, symbol: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
                Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.7)
            }
            .foregroundStyle(theme.secondaryInk.color)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(theme.secondaryInk.color).fixedSize(horizontal: false, vertical: true)
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 12)).foregroundStyle(theme.secondaryInk.color)
            Spacer()
            Text(v).font(.system(size: 12, weight: .medium).monospacedDigit())
        }
    }

    private func fmt(_ mm: Float) -> String { state.units.format(mm, withSymbol: false) }

    private func isAngle(_ c: SketchConstraint) -> Bool { if case .angle = c { return true }; return false }

    /// Slider bound to a feature parameter: one undo step per drag, live rebuild while dragging.
    private func slider(_ title: String, _ id: UUID, _ range: ClosedRange<Float>, format: @escaping (Float) -> String,
                        get: @escaping (FeatureKind) -> Float?, set: @escaping (inout FeatureKind, Float) -> Void) -> some View {
        ClaySlider(title,
                   value: Binding(get: { state.feature(id).flatMap { get($0.kind) } ?? range.lowerBound },
                                  set: { v in state.editFeature(id, live: true) { set(&$0, v) } }),
                   in: range, theme: theme, format: format,
                   onEditingChanged: { began in if began { state.pushUndo() } })
    }

    private func intSlider(_ title: String, _ id: UUID, _ range: ClosedRange<Int>,
                           get: @escaping (FeatureKind) -> Int?, set: @escaping (inout FeatureKind, Int) -> Void) -> some View {
        slider(title, id, Float(range.lowerBound)...Float(range.upperBound), format: { "\(Int($0.rounded()))" },
               get: { get($0).map(Float.init) }, set: { k, v in set(&k, Int(v.rounded())) })
    }
}
