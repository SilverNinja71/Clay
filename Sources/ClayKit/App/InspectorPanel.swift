import SwiftUI
import simd

/// Right-hand panel: settings for the current mode and the selected timeline step.
struct InspectorPanel: View {
    @Bindable var state: WorkspaceState
    let theme: StudioTheme

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                switch state.mode {
                case .sketch: sketchInspector
                case .model: modelInspector
                case .sculpt: sculptInspector
                case .dimension: dimensionInspector
                }
            }
            .padding(14)
        }
        .frame(maxHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
        .floatingPanel(theme)
        .foregroundStyle(theme.ink.color)
        .tint(theme.accent.color)
    }

    // MARK: Sketch

    @ViewBuilder private var sketchInspector: some View {
        section("Paper") {
            Picker("Paper", selection: Binding(get: { state.document.paper }, set: { state.document.paper = $0; state.scheduleSave() })) {
                ForEach(PaperStyle.allCases) { Image(systemName: $0.symbol).help($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            unitPicker
            Button { state.fitSketchView(state.activePlane) } label: { Label("Fit sheet to drawing", systemImage: "viewfinder") }
                .buttonStyle(.borderless)
        }
        if let front = state.timeline.sketch(.front), let side = state.timeline.sketch(.side),
           let off = SilhouetteMatcher.heightMismatch(front: front, side: side), off > 1.5 {
            section("Alignment") {
                Text("Side profile is \(state.units.format(off)) out of line with the front.")
                    .font(.caption).foregroundStyle(theme.secondaryInk.color)
                Button { state.matchSideHeight() } label: { Label("Match side height to front", systemImage: "arrow.up.and.down") }
            }
        }
        if let sel = state.sketchSelection, let path = state.sketchPath(sel) {
            section("Selected curve") {
                infoRow("Type", path.closed ? "Closed \(path.kind.rawValue)" : "Open \(path.kind.rawValue)")
                infoRow("Points", "\(path.anchors.count)")
                infoRow("Length", state.units.format(path.length))
                if !path.closed { Text("Open curves are half-profiles: they mirror around the dashed axis.").font(.caption).foregroundStyle(theme.secondaryInk.color) }
                HStack {
                    if path.closed { Button("Extrude") { state.extrude() } }
                    Button("Duplicate") { state.duplicate() }
                    Button("Delete", role: .destructive) { state.deleteSelection() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            let options = state.availableConstraints()
            section("Constraints") {
                if options.isEmpty {
                    Text("With Edit points (V), shift-click 1–4 points to constrain them.").font(.caption).foregroundStyle(theme.secondaryInk.color)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, c in
                        Button { state.addConstraint(c, plane: sel.plane, edit: c.value != nil) } label: {
                            Label(c.title, systemImage: c.symbol).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        if let s = state.timeline.sketch(state.activePlane), !s.constraints.isEmpty {
            section("\(state.activePlane.title) constraints") {
                ForEach(Array(s.constraints.enumerated()), id: \.offset) { i, c in
                    HStack {
                        Image(systemName: c.symbol).frame(width: 18)
                        Text(c.title).font(.system(size: 12))
                        Spacer()
                        if let v = c.value { Text(isAngle(c) ? String(format: "%.1f°", v) : state.units.format(v)).font(.system(size: 12).monospacedDigit()) }
                        Button { state.removeConstraint(plane: state.activePlane, at: i) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).foregroundStyle(theme.secondaryInk.color)
                    }
                }
            }
        }
        section("Tips") {
            Text("Draw one closed loop per view, or just one side of a symmetric shape. Endpoints near the axis snap to it, and a stroke that ends near its start closes itself.")
                .font(.caption).foregroundStyle(theme.secondaryInk.color)
        }
    }

    // MARK: Model

    @ViewBuilder private var modelInspector: some View {
        if let f = state.feature(state.selectedFeatureID) {
            section(f.name) {
                if let msg = state.statuses[f.id]?.message {
                    Label(msg, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                featureEditor(f)
            }
        }
        section("Quick actions") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 6)], spacing: 6) {
                ForEach(RadialAction.allCases.filter { $0 != .dimension }) { a in
                    Button { state.perform(a) } label: {
                        VStack(spacing: 3) { Image(systemName: a.symbol); Text(a.title).font(.system(size: 10, weight: .semibold)) }
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.bordered)
                }
            }
            HStack {
                Button { state.remesh() } label: { Label("Remesh", systemImage: "circle.hexagongrid") }
                Button { state.subdivide() } label: { Label("Subdivide", systemImage: "square.grid.3x3") }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        if state.stats.triangles > 0 {
            section("Body") {
                infoRow("Size", "\(fmt(state.stats.size.x)) × \(fmt(state.stats.size.y)) × \(fmt(state.stats.size.z)) \(state.units.symbol)")
                infoRow("Volume", String(format: "%.1f cm³", state.stats.volume / 1000))
                infoRow("Triangles", state.stats.triangles.formatted())
                infoRow("Watertight", state.stats.watertight ? "Yes — ready to print" : "No")
            }
        }
    }

    @ViewBuilder private func featureEditor(_ f: Feature) -> some View {
        switch f.kind {
        case .sketch(let s):
            Button { state.openFeature(f.id) } label: { Label("Edit \(s.plane.title.lowercased()) sketch", systemImage: "pencil") }
        case .loft:
            intSlider("Rings", f.id, 40...300) { if case .loft(let p) = $0 { return p.rings }; return nil } set: { k, v in if case .loft(var p) = k { p.rings = v; k = .loft(p) } }
            intSlider("Segments", f.id, 16...256) { if case .loft(let p) = $0 { return p.segments }; return nil } set: { k, v in if case .loft(var p) = k { p.segments = v; k = .loft(p) } }
            slider("Squareness", f.id, 0...1, format: { String(format: "%.2f", $0) }) { if case .loft(let p) = $0 { return p.squareness }; return nil } set: { k, v in if case .loft(var p) = k { p.squareness = v; k = .loft(p) } }
            Text("Changing rings or segments changes the mesh topology, which resets later sculpt layers.")
                .font(.caption2).foregroundStyle(theme.secondaryInk.color)
        case .edgeTreatment(let e):
            Picker("Style", selection: Binding(get: { e.style }, set: { v in state.editFeature(f.id) { if case .edgeTreatment(var x) = $0 { x.style = v; $0 = .edgeTreatment(x) } } })) {
                ForEach(EdgeTreatment.Style.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.pickerStyle(.segmented)
            Picker("Edge", selection: Binding(get: { e.edge }, set: { v in state.editFeature(f.id) { if case .edgeTreatment(var x) = $0 { x.edge = v; $0 = .edgeTreatment(x) } } })) {
                ForEach(EdgeTreatment.Edge.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.pickerStyle(.segmented)
            slider("Size", f.id, 0.2...20, format: { state.units.format($0) }) { if case .edgeTreatment(let x) = $0 { return x.size }; return nil } set: { k, v in if case .edgeTreatment(var x) = k { x.size = v; k = .edgeTreatment(x) } }
        case .shell(let s):
            slider("Wall", f.id, 0.4...15, format: { state.units.format($0) }) { if case .shell(let x) = $0 { return x.thickness }; return nil } set: { k, v in if case .shell(var x) = k { x.thickness = v; k = .shell(x) } }
            Toggle("Open top", isOn: Binding(get: { s.openTop }, set: { v in state.editFeature(f.id) { if case .shell(var x) = $0 { x.openTop = v; $0 = .shell(x) } } }))
        case .offset:
            slider("Distance", f.id, -10...10, format: { state.units.format($0) }) { if case .offset(let d) = $0 { return d }; return nil } set: { k, v in k = .offset(v) }
        case .split(let sp):
            let b = state.evaluator.meshBefore(state.timeline.index(of: f.id) ?? 0)?.bounds ?? state.sceneBounds
            slider("Height", f.id, b.min.y...max(b.max.y, b.min.y + 1), format: { state.units.format($0) }) { if case .split(let x) = $0 { return x.height }; return nil } set: { k, v in if case .split(var x) = k { x.height = v; k = .split(x) } }
            Picker("Keep", selection: Binding(get: { sp.keepBelow }, set: { v in state.editFeature(f.id) { if case .split(var x) = $0 { x.keepBelow = v; $0 = .split(x) } } })) {
                Text("Below").tag(true); Text("Above").tag(false)
            }.pickerStyle(.segmented)
        case .extrude(let p):
            slider("Depth", f.id, 0.5...200, format: { state.units.format($0) }) { if case .extrude(let x) = $0 { return x.depth }; return nil } set: { k, v in if case .extrude(var x) = k { x.depth = v; k = .extrude(x) } }
            Toggle("Symmetric", isOn: Binding(get: { p.symmetric }, set: { v in state.editFeature(f.id) { if case .extrude(var x) = $0 { x.symmetric = v; $0 = .extrude(x) } } }))
        case .remesh:
            slider("Voxel size", f.id, 0.4...4, format: { state.units.format($0) }) { if case .remesh(let x) = $0 { return x.voxelSize }; return nil } set: { k, v in if case .remesh(var x) = k { x.voxelSize = v; k = .remesh(x) } }
        case .sculpt(let layer):
            infoRow("Vertices moved", "\(layer.displacements.filter { $0 != .zero }.count.formatted())")
            Button("Clear sculpt layer", role: .destructive) {
                state.editFeature(f.id) { $0 = .sculpt(SculptLayer(vertexCount: layer.vertexCount)) }
            }
        case .transform(let t), .duplicate(let t):
            infoRow("Move", "\(fmt(t.translation.x)), \(fmt(t.translation.y)), \(fmt(t.translation.z))")
            infoRow("Rotate", String(format: "%.1f°", t.rotationDegrees))
            infoRow("Scale", "\(String(format: "%.2f", t.scale.x)) × \(String(format: "%.2f", t.scale.y)) × \(String(format: "%.2f", t.scale.z))")
        case .subdivide:
            Text("Each triangle split into four.").font(.caption).foregroundStyle(theme.secondaryInk.color)
        }
    }

    // MARK: Sculpt

    @ViewBuilder private var sculptInspector: some View {
        section(state.brush.kind.title) {
            plainSlider("Radius", value: $state.brush.radius, range: 1...40, format: { state.units.format($0) })
            plainSlider("Strength", value: $state.brush.strength, range: 0.02...1, format: { String(format: "%.0f%%", $0 * 100) })
            plainSlider("Spacing", value: $state.brush.spacing, range: 0.04...0.5, format: { String(format: "%.0f%%", $0 * 100) })
            Picker("Falloff", selection: $state.brush.falloff) {
                ForEach(Falloff.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Toggle(state.brush.kind.inverseTitle + " (invert)", isOn: $state.brush.invert)
            Toggle("X symmetry", isOn: $state.brush.symmetryX)
            Toggle("Pressure → strength", isOn: $state.brush.pressureStrength)
            Toggle("Pressure → radius", isOn: $state.brush.pressureRadius)
        }
        section("Topology") {
            Text("Grab and Inflate stretch triangles; remesh to make them even again.").font(.caption).foregroundStyle(theme.secondaryInk.color)
            HStack {
                Button { state.remesh() } label: { Label("Voxel remesh", systemImage: "circle.hexagongrid") }
                Button { state.subdivide() } label: { Label("Subdivide", systemImage: "square.grid.3x3") }
            }
            .buttonStyle(.bordered).controlSize(.small)
            infoRow("Triangles", state.stats.triangles.formatted())
        }
    }

    // MARK: Dimension

    @ViewBuilder private var dimensionInspector: some View {
        section("Units") { unitPicker }
        let items = state.callouts()
        section("Dimensions") {
            if items.isEmpty {
                Text("Generate 3D Clay to see the model's driving dimensions.").font(.caption).foregroundStyle(theme.secondaryInk.color)
            }
            ForEach(items) { c in
                Button { if c.editable { state.editingCallout = c.id } } label: {
                    HStack {
                        Image(systemName: c.driving ? "ruler" : "ruler.fill").foregroundStyle(c.driving ? theme.accent.color : theme.guideInk.color)
                        Text(c.title).font(.system(size: 12))
                        Spacer()
                        Text(state.units.format(c.value)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        section("How it works") {
            Text("Driving dimensions edit the sketches and the timeline rebuilds everything after them — sculpting included. Tap the base or rim of the model, or use Measure (M) for reference distances.")
                .font(.caption).foregroundStyle(theme.secondaryInk.color)
        }
    }

    // MARK: Pieces

    private var unitPicker: some View {
        Picker("Units", selection: Binding(get: { state.units }, set: { state.units = $0 })) {
            ForEach(LengthUnit.allCases) { Text($0.symbol).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(theme.secondaryInk.color).tracking(0.6)
            content()
        }
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

    private func plainSlider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, format: @escaping (Float) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(.system(size: 12)); Spacer(); Text(format(value.wrappedValue)).font(.system(size: 12).monospacedDigit()) }
            Slider(value: value, in: range)
        }
    }

    /// Slider bound to a feature parameter: one undo step per drag, live rebuild while dragging.
    private func slider(_ title: String, _ id: UUID, _ range: ClosedRange<Float>, format: @escaping (Float) -> String,
                        get: @escaping (FeatureKind) -> Float?, set: @escaping (inout FeatureKind, Float) -> Void) -> some View {
        let current = state.feature(id).flatMap { get($0.kind) } ?? range.lowerBound
        return VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(.system(size: 12)); Spacer(); Text(format(current)).font(.system(size: 12).monospacedDigit()) }
            Slider(value: Binding(get: { state.feature(id).flatMap { get($0.kind) } ?? range.lowerBound },
                                  set: { v in state.editFeature(id, live: true) { set(&$0, v) } }),
                   in: range,
                   onEditingChanged: { began in if began { state.pushUndo() } })
        }
    }

    private func intSlider(_ title: String, _ id: UUID, _ range: ClosedRange<Int>,
                           get: @escaping (FeatureKind) -> Int?, set: @escaping (inout FeatureKind, Int) -> Void) -> some View {
        slider(title, id, Float(range.lowerBound)...Float(range.upperBound), format: { "\(Int($0))" },
               get: { get($0).map(Float.init) }, set: { k, v in set(&k, Int(v.rounded())) })
    }
}
