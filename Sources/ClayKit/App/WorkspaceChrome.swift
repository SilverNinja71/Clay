import SwiftUI

// MARK: - Top bar

struct TopBar: View {
    @Bindable var state: WorkspaceState
    let theme: StudioTheme
    @Environment(StudioThemeStore.self) private var themes
    @Namespace private var modeNS

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ToolButton(symbol: "square.grid.2x2", label: "Library", theme: theme, size: 34) { state.close() }
                TextField("Untitled", text: $state.document.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                    .frame(width: 170)
                    .onSubmit { state.saveNow() }
            }
            .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 3)
            .floatingPanel(theme, radius: 22)

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                ForEach(WorkspaceMode.allCases) { m in
                    Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { state.setMode(m) } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: m.symbol)
                            Text(m.title)
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .foregroundStyle(state.mode == m ? theme.onAccent.color : theme.ink.color)
                        .background {
                            if state.mode == m {
                                Capsule().fill(theme.accent.color).matchedGeometryEffect(id: "mode", in: modeNS)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(m == .sculpt && state.mesh == nil)
                    .opacity(m == .sculpt && state.mesh == nil ? 0.4 : 1)
                    .help("\(m.title) mode (Tab cycles)")
                }
            }
            .padding(4)
            .floatingPanel(theme, radius: 24)

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                ToolButton(symbol: "arrow.uturn.backward", label: "Undo (⌘Z, two-finger tap)", theme: theme, size: 34) { state.undo() }
                    .disabled(!state.canUndo).opacity(state.canUndo ? 1 : 0.4)
                ToolButton(symbol: "arrow.uturn.forward", label: "Redo (⇧⌘Z, three-finger tap)", theme: theme, size: 34) { state.redo() }
                    .disabled(!state.canRedo).opacity(state.canRedo ? 1 : 0.4)
                ToolButton(symbol: "book.closed", label: "Project cover", theme: theme, size: 34) { state.coverEditorPresented = true }
                Menu {
                    ForEach(StudioTheme.all) { t in
                        Button { themes.current = t } label: {
                            Label(t.name, systemImage: themes.current.id == t.id ? "checkmark" : "paintpalette")
                        }
                    }
                } label: {
                    Image(systemName: "paintpalette").font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34).foregroundStyle(theme.ink.color)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Studio theme")
                ToolButton(symbol: "keyboard", label: "Keyboard shortcuts", theme: theme, size: 34) { state.shortcutsPresented.toggle() }
                    .popover(isPresented: $state.shortcutsPresented) { ShortcutSheet(theme: theme) }
                ToolButton(symbol: "sidebar.right", label: "Inspector (N)", isOn: state.showInspector, theme: theme, size: 34) { state.showInspector.toggle() }
                ToolButton(symbol: "square.and.arrow.up", label: "Export (⌘E)", theme: theme, size: 34) { state.exportPresented = true }
            }
            .padding(3)
            .floatingPanel(theme, radius: 22)
        }
    }
}

// MARK: - Tool palette (left)

struct ToolPalette: View {
    @Bindable var state: WorkspaceState
    let theme: StudioTheme

    var body: some View {
        VStack(spacing: 4) {
            switch state.mode {
            case .sketch:
                ForEach(SketchTool.allCases) { t in
                    ToolButton(symbol: t.symbol, label: "\(t.title) (\(t.hotkey))", isOn: state.sketchTool == t, theme: theme) {
                        state.selectSketchTool(t)
                    }
                }
                divider
                ToolButton(symbol: "square.fill", label: "Front plane (1)", isOn: !state.splitSketch && state.activePlane == .front, theme: theme) {
                    state.splitSketch = false; state.setPlane(.front)
                }
                ToolButton(symbol: "square.lefthalf.filled", label: "Side plane (3)", isOn: !state.splitSketch && state.activePlane == .side, theme: theme) {
                    state.splitSketch = false; state.setPlane(.side)
                }
                ToolButton(symbol: "rectangle.split.2x1", label: "Split view: front and side", isOn: state.splitSketch, theme: theme) {
                    state.splitSketch.toggle()
                }
            case .model:
                ForEach(ModelTool.allCases) { t in
                    ToolButton(symbol: t.symbol, label: t.title, isOn: state.modelTool == t, theme: theme) { state.modelTool = t }
                }
                divider
                ToolButton(symbol: "square.stack.3d.up", label: "Extrude sketch (E)", theme: theme) { state.extrude() }
                ToolButton(symbol: "square.grid.3x3.square", label: "Wireframe (W)", isOn: state.showWireframe, theme: theme) { state.showWireframe.toggle() }
                ToolButton(symbol: "pencil.and.outline", label: "Show sketches", isOn: state.showSketches, theme: theme) { state.showSketches.toggle() }
            case .sculpt:
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(BrushKind.allCases) { b in
                            ToolButton(symbol: b.symbol, label: "\(b.title) (\(b.hotkey))", isOn: state.brush.kind == b, theme: theme) { state.brush.kind = b }
                        }
                    }
                }
                .frame(maxHeight: 440)
                divider
                ToolButton(symbol: "minus.circle", label: "Invert (\(state.brush.kind.inverseTitle)) — or hold Ctrl", isOn: state.brush.invert, theme: theme) { state.brush.invert.toggle() }
                ToolButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", label: "X symmetry (M)", isOn: state.brush.symmetryX, theme: theme) { state.brush.symmetryX.toggle() }
            case .dimension:
                ToolButton(symbol: "ruler", label: "Inspect dimensions", isOn: state.dimensionTool == .inspect, theme: theme) { state.dimensionTool = .inspect }
                ToolButton(symbol: "point.topleft.down.to.point.bottomright.curvepath", label: "Measure two points (M)", isOn: state.dimensionTool == .measure, theme: theme) { state.dimensionTool = .measure }
                divider
                ToolButton(symbol: "trash", label: "Clear measurements", theme: theme) { state.measurements.removeAll(); state.pendingMeasure = nil }
            }
        }
        .padding(5)
        .floatingPanel(theme, radius: 24)
    }

    private var divider: some View {
        Rectangle().fill(theme.panelStroke.color).frame(width: 24, height: 1).padding(.vertical, 4)
    }
}

// MARK: - Bottom: generate, smooth, status

struct GenerateButton: View {
    let state: WorkspaceState
    let theme: StudioTheme
    @State private var pulse = false

    var body: some View {
        let highlight = state.tutorial?.highlightsGenerate ?? false
        Button { state.generateClay() } label: {
            HStack(spacing: 10) {
                Image(systemName: "cube.transparent.fill").font(.system(size: 18, weight: .semibold))
                Text("Generate 3D Clay").font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(theme.onAccent.color)
            .padding(.horizontal, 26).padding(.vertical, 14)
            .background(Capsule().fill(theme.accent.color))
            .shadow(color: theme.accent.color.opacity(highlight ? 0.6 : 0.3), radius: highlight && pulse ? 22 : 10, y: 4)
            .scaleEffect(highlight && pulse ? 1.06 : 1)
        }
        .buttonStyle(PressableStyle())
        .keyboardShortcut(.return, modifiers: .command)
        .help("Loft the front and side silhouettes into a solid (⌘↩)")
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

struct HoldToSmoothButton: View {
    let state: WorkspaceState
    let theme: StudioTheme
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "drop.fill")
            Text(state.smoothHeld ? "Smoothing…" : "Hold to Smooth")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(state.smoothHeld ? theme.onAccent.color : theme.ink.color)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Capsule().fill(state.smoothHeld ? theme.accent.color : theme.panel.color))
        .overlay(Capsule().strokeBorder(theme.panelStroke.color))
        .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, perform: {}, onPressingChanged: { state.smoothHeld = $0 })
        .help("Hold with one finger while you sculpt with the other hand (Shift does the same)")
        .animation(.spring(response: 0.25), value: state.smoothHeld)
    }
}

struct StatusReadout: View {
    let state: WorkspaceState
    let theme: StudioTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !state.statusText.isEmpty {
                Text(state.statusText)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.onAccent.color)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(theme.accent.color))
            }
            if state.stats.triangles > 0 && state.mode != .sketch {
                HStack(spacing: 10) {
                    Label("\(state.stats.triangles.formatted()) tris", systemImage: "triangle")
                    Label(state.stats.watertight ? "Watertight" : "Open", systemImage: state.stats.watertight ? "checkmark.seal" : "exclamationmark.triangle")
                    Text(String(format: "%.1f cm³", state.stats.volume / 1000))
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.secondaryInk.color)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .floatingPanel(theme, radius: 12)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Timeline

struct TimelineBar: View {
    let state: WorkspaceState
    let theme: StudioTheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(theme.secondaryInk.color)
                .help("History timeline — click a step to edit it; right-click for more")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        let features = state.timeline.features
                        ForEach(Array(features.enumerated()), id: \.element.id) { i, f in
                            if i > 0 {
                                Image(systemName: "chevron.compact.right").font(.system(size: 11)).foregroundStyle(theme.secondaryInk.color.opacity(0.6))
                            }
                            FeatureChip(state: state, feature: f, index: i, theme: theme)
                                .id(f.id)
                            if i == state.timeline.activeCount - 1 && state.timeline.marker != nil {
                                Button { state.rollBack(to: nil) } label: {
                                    Image(systemName: "forward.end.fill").foregroundStyle(theme.accent.color)
                                }
                                .buttonStyle(.plain)
                                .help("Rolled back here — click to roll forward to the end")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: state.timeline.features.count) { _, _ in
                    if let last = state.timeline.features.last { withAnimation { proxy.scrollTo(last.id, anchor: .trailing) } }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .floatingPanel(theme, radius: 18)
    }
}

struct FeatureChip: View {
    let state: WorkspaceState
    let feature: Feature
    let index: Int
    let theme: StudioTheme

    var body: some View {
        let selected = state.selectedFeatureID == feature.id
        let status = state.statuses[feature.id] ?? .ok
        let inactive = feature.suppressed || status == .rolledBack
        Button { state.openFeature(feature.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: feature.kind.symbol).font(.system(size: 12, weight: .semibold))
                Text(feature.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                switch status {
                case .warning: Circle().fill(Color.orange).frame(width: 6, height: 6)
                case .error: Circle().fill(Color.red).frame(width: 6, height: 6)
                default: EmptyView()
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(selected ? theme.onAccent.color : theme.ink.color)
            .background(Capsule().fill(selected ? theme.accent.color : theme.canvas.color.opacity(0.55)))
            .overlay(Capsule().strokeBorder(theme.panelStroke.color))
            .opacity(inactive ? 0.4 : 1)
            .strikethrough(feature.suppressed)
        }
        .buttonStyle(PressableStyle())
        .help(status.message ?? feature.name)
        .contextMenu {
            Button("Edit") { state.openFeature(feature.id) }
            Button(feature.suppressed ? "Unsuppress" : "Suppress") { state.toggleSuppressed(feature.id) }
            Button("Roll back to here") { state.rollBack(to: feature.id) }
            Divider()
            Button(feature.sketch != nil ? "Clear sketch" : "Delete", role: .destructive) { state.deleteFeature(feature.id) }
        }
    }
}

// MARK: - Shortcuts

struct ShortcutSheet: View {
    let theme: StudioTheme
    private let rows: [(String, String)] = [
        ("Tab / ⇧Tab", "Cycle Sketch → Model → Sculpt → Dimension"),
        ("1 / 3 / 7  (numpad)", "Front / Right / Top view  (Ctrl = opposite)"),
        ("5  (numpad)", "Perspective ↔ Orthographic"),
        ("Home", "Frame everything"),
        ("G / R / S", "Move / Rotate / Scale, then X Y Z to lock an axis, type a number, Enter"),
        ("E", "Extrude the selected sketch shape"),
        ("⇧D", "Duplicate"),
        ("X / Delete", "Delete"),
        ("⌘Z / ⇧⌘Z", "Undo / Redo"),
        ("MMB drag", "Orbit · ⇧ pan · Ctrl zoom  (or ⌥ + drag)"),
        ("Scroll / pinch", "Zoom  ·  trackpad swipe orbits"),
        ("Sculpt: C X G S I P", "Clay, Draw, Grab, Smooth, Inflate, Pinch"),
        ("Sculpt: ⇧C ⇧K ⇧T ⇧S", "Clay Strips, Crease, Flatten, Scrape"),
        ("Sculpt: [ ]  ⇧[ ⇧]", "Brush radius · strength"),
        ("Sculpt: hold ⇧ / Ctrl", "Smooth / invert while stroking"),
        ("Sketch: P ⇧P L C B V D", "Pencil, Pen, Line, Circle, Rectangle, Edit, Dimension"),
        ("Pen: click / drag", "Corner point / curve point · click the first point to close · ⏎ to finish · ⌥-drag breaks the handle"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard shortcuts").font(.headline)
            Text("Top-row 1/3/7/5 work like the numpad (Blender's “emulate numpad”).")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(rows, id: \.0) { r in
                    GridRow {
                        Text(r.0).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text(r.1).font(.system(size: 12))
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 480)
    }
}
