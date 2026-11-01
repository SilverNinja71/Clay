import SwiftUI
import simd

// MARK: - Plane operations

/// Positioned sketch planes (Feather 3D / Shapr3D style): add, place, align, and form clay
/// through the curves drawn on them.
extension WorkspaceState {

    /// Adds a sketch plane and makes it active. With no arguments it faces the camera (snapped to
    /// the nearest world axis) through the middle of the scene.
    @discardableResult
    public func addPlane(normal: Vec3? = nil, at origin: Vec3? = nil) -> UUID {
        var n = normal ?? snappedViewAxis()
        if simd_length(n) < 1e-4 { n = Vec3(0, 0, 1) }
        let b = sceneBounds
        let o = origin ?? (mesh != nil || !timeline.planes.allSatisfy { $0.curves.isEmpty } ? b.center : camera.target)
        let side = max(80, min(max(b.size.x, b.size.y, b.size.z) * 1.4, 400))
        let plane = SketchPlane.facing(n, at: o, name: timeline.nextName("Plane"), size: Vec2(side, side))
        appendFeature(Feature(plane: plane))
        if mode != .sketch { setMode(.sketch) }
        sketchIn3D = true
        setPlane(id: plane.id)
        hapticTick += 1
        showToast("\(plane.name) added — draw on it, or drag the gizmo to place it", symbol: "square.on.square")
        return plane.id
    }

    /// A plane lying on the clay surface at a tapped point (radial menu → Plane).
    public func addPlaneOnSurface(at point: Vec3, normal: Vec3) {
        addPlane(normal: normal == .zero ? snappedViewAxis() : normal, at: point)
    }

    /// Copies a plane (with its curves) 30 mm further along its normal — handy for cross-sections.
    public func duplicatePlane(_ id: UUID) {
        guard var p = timeline.plane(id) else { return }
        p = SketchPlane(name: timeline.nextName("Plane"), origin: p.origin + p.normal * 30, normal: p.normal, up: p.up,
                        size: p.size, sketch: Sketch(paths: p.curves.map { var c = $0; c.id = UUID(); return c }))
        appendFeature(Feature(plane: p))
        setPlane(id: p.id)
        showToast("Copied 30 mm along the normal", symbol: "plus.square.on.square")
    }

    /// Glides the camera to look straight at a plane (orthographic), like Shapr3D's "look at".
    public func alignView(to id: UUID?) {
        guard let p = timeline.plane(id) else { return }
        var g = camera
        g.yaw = atan2(p.normal.x, p.normal.z)
        g.pitch = asin(clamp(p.normal.y, -0.9995, 0.9995))
        g.target = p.centerWorld
        let sh = p.sheet
        g.distance = max(sh.max.x - sh.min.x, sh.max.y - sh.min.y) * 1.35 / (2 * tan(g.fovY / 2))
        g.orthographic = true
        cameraAnimator.goal = g
    }

    public func setPlaneVisible(_ id: UUID, _ visible: Bool) {
        commit { $0.editPlane(id) { $0.isVisible = visible } }
    }

    public func setPlaneLocked(_ id: UUID, _ locked: Bool) {
        commit { $0.editPlane(id) { $0.isLocked = locked } }
    }

    /// Distance of the plane from the world origin along its normal ("offset").
    public func planeOffset(_ id: UUID?) -> Float {
        guard let p = timeline.plane(id) else { return 0 }
        return simd_dot(p.origin, p.normal)
    }

    public func setPlaneOffset(_ id: UUID, _ value: Float, live: Bool) {
        let change: (inout Timeline) -> Void = { tl in tl.editPlane(id) { p in p.origin += p.normal * (value - simd_dot(p.origin, p.normal)) } }
        if live { liveChange(change) } else { commit(change) }
    }

    /// Turns the plane around (its normal flips; the drawing stays where it is in 3D).
    public func flipPlane(_ id: UUID) {
        commit { $0.editPlane(id) { p in
            p.normal = -p.normal
            p.curves = p.curves.map { $0.transformed { Vec2(-$0.x, $0.y) } }
        } }
    }

    func snappedViewAxis() -> Vec3 {
        let v = -camera.forward
        let a = Vec3(abs(v.x), abs(v.y), abs(v.z))
        if a.y >= a.x && a.y >= a.z { return Vec3(0, v.y >= 0 ? 1 : -1, 0) }
        if a.x >= a.z { return Vec3(v.x >= 0 ? 1 : -1, 0, 0) }
        return Vec3(0, 0, v.z >= 0 ? 1 : -1)
    }

    // MARK: Form Clay

    /// "Form Clay": lofts through the closed curves on every visible plane. Without positioned
    /// planes it is the classic front/side silhouette loft ("Generate 3D Clay").
    public func formClay() {
        guard formsFromPlanes else { generateClay(); return }
        let ids = timeline.planes.filter { $0.isVisible && $0.curves.contains(where: \.closed) }.map(\.id)
        if let i = timeline.features.firstIndex(where: { if case .sectionLoft = $0.kind { return true }; return false }) {
            editFeature(timeline.features[i].id) { if case .sectionLoft(var p) = $0 { p.planes = ids; $0 = .sectionLoft(p) } }
        } else {
            appendFeature(Feature(name: "Form Clay", kind: .sectionLoft(SectionLoftParameters(planes: ids))))
        }
        guard let m = mesh, !m.isEmpty else {
            showToast(statuses.values.compactMap(\.message).first ?? "Couldn't form the clay", symbol: "exclamationmark.triangle")
            return
        }
        mode = .model
        bodySelected = true
        cameraAnimator.goal = OrbitCamera.preset(.threeQuarter, framing: m.bounds)
        loftReveal = 0
        successTick += 1
        showToast("Formed from \(ids.count) plane\(ids.count == 1 ? "" : "s")", symbol: "square.3.layers.3d")
    }

    // MARK: Drawing on planes in the 3D view

    /// Nearest visible plane under a pointer ray (its sheet must contain the hit).
    func planeHit(_ r: Ray, excluding: UUID? = nil) -> (id: UUID, local: Vec2, distance: Float)? {
        var best: (UUID, Vec2, Float)?
        for p in timeline.planes where p.isVisible && showsIn3D(p) && p.id != excluding {
            guard let h = p.intersect(r), p.sheetContains(h.local) else { continue }
            if best == nil || h.distance < best!.2 { best = (p.id, h.local, h.distance) }
        }
        return best.map { ($0.0, $0.1, $0.2) }
    }

    /// Snap radius on a plane, in millimetres, for a 12-point screen distance.
    var sketch3DSnap: Float { camera.worldPerPoint(viewHeight: viewportSize.height) * 12 }

    /// Pointer down in the 3D sketch view. Returns true when it started a drawing interaction.
    func sketch3DDown(_ e: PointerEvent) -> Bool {
        let r = ray(at: e.location)
        // Double-click a plane: make it active and look straight at it.
        if e.clickCount >= 2, livePen.isEmpty, livePolyline.isEmpty, let hit = planeHit(r) {
            setPlane(id: hit.id)
            alignView(to: hit.id)
            return true
        }
        guard let plane = activePlane, plane.isVisible else {
            if let hit = planeHit(r) { setPlane(id: hit.id); return true }
            return false
        }
        let activeHit = plane.intersect(r).flatMap { plane.sheetContains($0.local, margin: 25) ? $0 : nil }
        // Drawing always goes to the active plane, even through other sheets in front of it.
        // Clicking where the active plane isn't, but another plane is, switches to that one.
        guard let h = activeHit else {
            if livePen.isEmpty, livePolyline.isEmpty, let other = planeHit(r, excluding: plane.id) {
                setPlane(id: other.id)
                showToast("Drawing on \(timeline.plane(other.id)?.name ?? "plane")", symbol: "square.on.square")
                return true
            }
            return false
        }
        livePlane = plane.id
        sketchHover = h.local
        sketchDown(h.local, plane: plane.id, snapR: sketch3DSnap, event: e)
        return true
    }

    func sketch3DDragged(_ e: PointerEvent) {
        guard let id = livePlane, let p = timeline.plane(id), let h = p.intersect(ray(at: e.location)) else { return }
        sketchHover = h.local
        sketchDragged(h.local, plane: id, snapR: sketch3DSnap, event: e)
    }

    func sketch3DUp(_ e: PointerEvent, cancelled: Bool) {
        guard let id = livePlane, let p = timeline.plane(id) else { return }
        let local = p.intersect(ray(at: e.location))?.local ?? sketchHover ?? .zero
        sketchUp(local, plane: id, snapR: sketch3DSnap, cancelled: cancelled)
    }

    func sketch3DHover(_ e: PointerEvent) {
        guard let p = activePlane, let h = p.intersect(ray(at: e.location)), p.sheetContains(h.local, margin: 25) else {
            sketchHover = nil; return
        }
        sketchHover = h.local
        livePlane = p.id
    }
}

// MARK: - Planes panel

/// Inspector section listing the sketch planes: activate, show/hide, lock, look at, place.
struct SketchPlanesSection: View {
    @Bindable var state: WorkspaceState
    let theme: StudioTheme
    var compact = false
    @State private var offsetDrag = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Image(systemName: "square.3.layers.3d").font(.system(size: 10, weight: .bold))
                Text("PLANES").font(.system(size: 10, weight: .bold)).tracking(0.7)
                Spacer()
                Button { state.addPlane() } label: { Label("Plane", systemImage: "plus") }
                    .buttonStyle(ClayPillButtonStyle(theme: theme, prominent: true))
                    .help("Add a sketch plane (⇧A)")
            }
            .foregroundStyle(theme.secondaryInk.color)

            if !compact {
                ClaySegmented([.init(false, "Sheet", symbol: "doc"), .init(true, "3D", symbol: "cube")],
                              selection: $state.sketchIn3D, theme: theme)
            }

            VStack(spacing: 4) {
                ForEach(Array(state.timeline.planes.enumerated()), id: \.element.id) { i, p in
                    row(p, index: i)
                }
            }

            if !compact, let p = state.activePlane, p.standard == nil {
                activeControls(p)
            }

            if state.formsFromPlanes {
                Button { state.formClay() } label: {
                    Label(state.timeline.formIndex == nil ? "Form Clay" : "Re-form Clay", systemImage: "square.3.layers.3d")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ClayPillButtonStyle(theme: theme, prominent: true))
                .help("Loft through the closed curve on every visible plane (Ctrl+Tab forms and starts sculpting)")
            }
        }
    }

    private func row(_ p: SketchPlane, index: Int) -> some View {
        let active = p.id == state.activePlaneID
        let c = state.planeColor(p, index: index)
        return HStack(spacing: 8) {
            Button {
                state.setPlane(id: p.id)
                if state.mode != .sketch { state.setMode(.sketch) }
                if p.standard == nil { state.sketchIn3D = true }
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(.sRGB, red: Double(pow(c.x, 1 / 2.2)), green: Double(pow(c.y, 1 / 2.2)), blue: Double(pow(c.z, 1 / 2.2))))
                        .frame(width: 10, height: 10)
                    Text(p.name).font(.system(size: 12, weight: active ? .bold : .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(p.curves.count)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(theme.secondaryInk.color)
                        .help("Curves on this plane")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            iconToggle(p.isVisible ? "eye" : "eye.slash", on: p.isVisible, help: p.isVisible ? "Hide" : "Show") {
                state.setPlaneVisible(p.id, !p.isVisible)
            }
            if p.standard == nil {
                iconToggle(p.isLocked ? "lock.fill" : "lock.open", on: p.isLocked, help: p.isLocked ? "Unlock position" : "Lock position") {
                    state.setPlaneLocked(p.id, !p.isLocked)
                }
            }
            iconToggle("scope", on: false, help: "Look straight at this plane") {
                state.setPlane(id: p.id)
                if state.mode != .sketch { state.setMode(.sketch) }
                state.sketchIn3D = true
                state.alignView(to: p.id)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(active ? theme.accent.color.opacity(0.14) : theme.canvas.color.opacity(theme.isDark ? 0.4 : 0.55)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(active ? theme.accent.color.opacity(0.7) : .clear, lineWidth: 1.2))
        .opacity(p.isVisible ? 1 : 0.55)
        .contextMenu {
            Button("Look at") { state.setPlane(id: p.id); state.sketchIn3D = true; state.alignView(to: p.id) }
            Button("Copy 30 mm along normal") { state.duplicatePlane(p.id) }
            if p.standard == nil {
                Button("Flip") { state.flipPlane(p.id) }
                Divider()
                Button("Delete plane", role: .destructive) { state.deleteFeature(p.id) }
            }
        }
    }

    private func iconToggle(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(on ? theme.accent.color : theme.secondaryInk.color)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }

    @ViewBuilder private func activeControls(_ p: SketchPlane) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ClaySegmented([.init(ModelTool.move, "Move", symbol: "arrow.up.and.down.and.arrow.left.and.right"),
                           .init(ModelTool.rotate, "Rotate", symbol: "arrow.triangle.2.circlepath"),
                           .init(ModelTool.scale, "Size", symbol: "arrow.up.left.and.arrow.down.right")],
                          selection: $state.planeGizmo, theme: theme)
                .disabled(p.isLocked)
            ClaySlider("Offset", value: Binding(get: { state.planeOffset(p.id) }, set: { state.setPlaneOffset(p.id, $0, live: true) }),
                       in: -200...200, theme: theme, format: { state.units.format($0) },
                       onEditingChanged: { began in if began { state.pushUndo() } })
                .disabled(p.isLocked)
            HStack(spacing: 6) {
                Button { state.alignView(to: p.id) } label: { Label("Look at", systemImage: "scope") }
                Button { state.duplicatePlane(p.id) } label: { Label("Copy +30", systemImage: "plus.square.on.square") }
                Button { state.flipPlane(p.id) } label: { Label("Flip", systemImage: "arrow.left.arrow.right") }
            }
            .buttonStyle(ClayPillButtonStyle(theme: theme))
            Text("Drag the gizmo, or press G / R / S, to place the plane. Right-click the clay → Plane to sit a plane on its surface.")
                .font(.system(size: 11)).foregroundStyle(theme.secondaryInk.color).fixedSize(horizontal: false, vertical: true)
        }
    }
}
