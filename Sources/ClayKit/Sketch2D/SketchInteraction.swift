import SwiftUI
import simd

enum AnchorPart: Sendable { case point, inHandle, outHandle }

enum SketchDrag {
    case freehand
    case shape
    case anchor(pathID: UUID, index: Int, part: AnchorPart, started: Bool)
    case path(pathID: UUID, last: Vec2, started: Bool)
    case pan(last: CGPoint)
    case erase(started: Bool)
}

/// Sketch-plane editing: drawing tools, point editing, constraints and sketch view navigation.
extension WorkspaceState {

    // MARK: Lookup

    public func sketchPath(_ sel: SketchSelection) -> SketchPath? {
        timeline.sketch(sel.plane)?.paths.first { $0.id == sel.pathID }
    }

    public func sketchViewTransform(_ plane: SketchPlane) -> SketchViewTransform {
        if let t = sketchViews[plane] { return t }
        let size = sketchCanvasSizes[plane] ?? viewportSize
        return defaultSketchView(plane, size: size)
    }

    func defaultSketchView(_ plane: SketchPlane, size: CGSize) -> SketchViewTransform {
        var lo = Vec2(-45, 0), hi = Vec2(45, 125)
        for p in [SketchPlane.front, .side] {
            if let b = timeline.sketch(p)?.bounds { lo = simd_min(lo, b.min); hi = simd_max(hi, b.max) }
        }
        // Keep the drawing clear of the floating toolbars, inspector and tutorial card.
        let right: CGFloat = showInspector ? 300 : 40
        let top: CGFloat = 90 + (tutorial != nil ? 200 : 0)
        let insets: (CGFloat, CGFloat, CGFloat, CGFloat) = splitSketch
            ? (top, plane == .front ? 90 : 20, 120, plane == .front ? 20 : right)
            : (top, 90, 120, right)
        return .fitting(min: lo, max: hi, size: size, insets: insets)
    }

    public func fitSketchView(_ plane: SketchPlane) {
        let size = sketchCanvasSizes[plane] ?? viewportSize
        sketchViews[plane] = defaultSketchView(plane, size: size)
    }

    // MARK: Handlers

    func sketchHandlers(_ plane: SketchPlane) -> PointerHandlers {
        var h = PointerHandlers()
        h.pointer = { [weak self] e in MainActor.assumeIsolated { self?.sketchPointer(e, plane: plane) } }
        h.scroll = { [weak self] e in MainActor.assumeIsolated { self?.sketchScroll(e, plane: plane) } }
        h.magnify = { [weak self] f, at in MainActor.assumeIsolated { self?.zoomSketch(plane, by: f, at: at) } }
        h.twoFingerPan = { [weak self] d in MainActor.assumeIsolated { self?.panSketch(plane, d.width, d.height) } }
        h.multiTap = { [weak self] n in MainActor.assumeIsolated { n == 2 ? self?.undo() : self?.redo() } }
        h.pencilDoubleTap = { [weak self] in MainActor.assumeIsolated { self?.pencilDoubleTap() } }
        h.resized = { [weak self] s in MainActor.assumeIsolated {
            guard let self, s.width > 1, s.height > 1 else { return }
            let first = self.sketchCanvasSizes[plane] == nil
            self.sketchCanvasSizes[plane] = s
            if first && self.sketchViews[plane] == nil { self.fitSketchView(plane) }
        } }
        return h
    }

    func zoomSketch(_ plane: SketchPlane, by f: CGFloat, at q: CGPoint) {
        var t = sketchViewTransform(plane)
        t.zoom(by: f, around: q, size: sketchCanvasSizes[plane] ?? viewportSize)
        sketchViews[plane] = t
    }

    func panSketch(_ plane: SketchPlane, _ dx: CGFloat, _ dy: CGFloat) {
        var t = sketchViewTransform(plane)
        t.pan(dx: dx, dy: dy)
        sketchViews[plane] = t
    }

    func sketchScroll(_ e: ScrollEvent, plane: SketchPlane) {
        if !e.precise || e.modifiers.contains(.command) || e.modifiers.contains(.control) {
            let amount = e.precise ? e.delta.height * 0.01 : e.delta.height * 0.1
            zoomSketch(plane, by: exp(amount), at: e.location)
        } else {
            panSketch(plane, e.delta.width, e.delta.height)
        }
    }

    // MARK: Pointer

    func sketchPointer(_ e: PointerEvent, plane: SketchPlane) {
        let size = sketchCanvasSizes[plane] ?? viewportSize
        let t = sketchViewTransform(plane)
        let p = t.toPlane(e.location, size: size)
        let snapR = Float(12 / t.scale)
        if e.device == .pencil && e.phase == .down { pencilSeen = true }
        if e.phase == .down && activePlane != plane { activePlane = plane }

        if modal != nil {
            switch e.phase {
            case .moved, .dragged: updateModal(pointer: e.location)
            case .down: if e.button == .secondary { cancelModal() } else { confirmModal() }
            default: break
            }
            return
        }

        switch e.phase {
        case .moved:
            sketchHover = p; livePlane = plane
            return
        case .exited:
            sketchHover = nil
            return
        case .down:
            if e.button == .middle || (e.device == .finger && pencilSeen) || (e.button == .primary && e.modifiers.contains(.option) && sketchTool != .edit) {
                sketchDrag = .pan(last: e.location); return
            }
            if e.button == .secondary {
                if !livePolyline.isEmpty { finishPolyline(closed: false) } else { sketchSelection = nil }
                return
            }
            livePlane = plane
            sketchDown(p, plane: plane, snapR: snapR, event: e)
        case .dragged:
            if case .pan(let last)? = sketchDrag {
                panSketch(plane, e.location.x - last.x, e.location.y - last.y)
                sketchDrag = .pan(last: e.location)
                return
            }
            sketchHover = p
            sketchDragged(p, plane: plane, snapR: snapR, event: e)
        case .up, .cancelled:
            sketchUp(p, plane: plane, snapR: snapR, cancelled: e.phase == .cancelled)
        }
    }

    private func sketchDown(_ p: Vec2, plane: SketchPlane, snapR: Float, event e: PointerEvent) {
        switch sketchTool {
        case .pencil:
            liveStroke = [p]
            sketchDrag = .freehand
        case .line:
            var q = snapToAxis(p, snapR)
            if e.modifiers.contains(.shift), let last = livePolyline.last { q = orthoSnap(q, from: last) }
            if livePolyline.count >= 3, simd_distance(q, livePolyline[0]) < snapR {
                finishPolyline(closed: true)
            } else if e.clickCount >= 2 && !livePolyline.isEmpty {
                finishPolyline(closed: false)
            } else {
                livePolyline.append(q)
            }
        case .circle, .rectangle:
            liveShape = ShapeDrag(start: p, end: p)
            sketchDrag = .shape
        case .edit:
            editDown(p, plane: plane, snapR: snapR, modifiers: e.modifiers)
        case .eraser:
            sketchDrag = .erase(started: false)
            erase(at: p, plane: plane, snapR: snapR)
        case .dimension:
            dimensionDown(p, plane: plane, snapR: snapR)
        }
    }

    private func sketchDragged(_ p: Vec2, plane: SketchPlane, snapR: Float, event e: PointerEvent) {
        switch sketchDrag {
        case .freehand?:
            if let last = liveStroke.last, simd_distance(last, p) < snapR * 0.04 { return }
            liveStroke.append(p)
        case .shape?:
            liveShape?.end = e.modifiers.contains(.shift) && sketchTool == .rectangle ? squareSnap(liveShape!.start, p) : p
        case .anchor(let pid, let idx, let part, let started)?:
            if !started { pushUndo(); sketchDrag = .anchor(pathID: pid, index: idx, part: part, started: true) }
            moveAnchor(plane: plane, pid, idx, part, to: snapToAxis(p, snapR))
        case .path(let pid, let last, let started)?:
            if !started { pushUndo() }
            let d = p - last
            liveChange { $0.editSketch(plane) { s in if let i = s.pathIndex(pid) { s.paths[i].transform { $0 + d } } } }
            sketchDrag = .path(pathID: pid, last: p, started: true)
        case .erase?:
            erase(at: p, plane: plane, snapR: snapR)
        default:
            break
        }
    }

    private func sketchUp(_ p: Vec2, plane: SketchPlane, snapR: Float, cancelled: Bool) {
        defer { sketchDrag = nil }
        switch sketchDrag {
        case .freehand?:
            if cancelled { liveStroke = []; return }
            finishFreehand(plane: plane, snapR: snapR)
        case .shape?:
            defer { liveShape = nil }
            guard !cancelled, let s = liveShape else { return }
            let path: SketchPath
            if sketchTool == .circle {
                let r = simd_distance(s.start, s.end)
                guard r > 1 else { return }
                path = .circle(center: s.start, radius: r)
            } else {
                guard abs(s.end.x - s.start.x) > 1, abs(s.end.y - s.start.y) > 1 else { return }
                path = .rectangle(s.start, s.end)
            }
            addPath(path, plane: plane)
        case .anchor(_, _, _, true)?, .path(_, _, true)?:
            // Re-solve constraints after a manual edit.
            if !(timeline.sketch(plane)?.constraints.isEmpty ?? true) {
                liveChange { $0.editSketch(plane) { ConstraintSolver.solve(&$0) } }
            }
            tutorial?.handle(.sketchCommitted(plane), in: self)
        default:
            break
        }
    }

    // MARK: Freehand

    private func finishFreehand(plane: SketchPlane, snapR: Float) {
        var pts = liveStroke
        liveStroke = []
        let length = zip(pts, pts.dropFirst()).reduce(Float(0)) { $0 + simd_distance($1.0, $1.1) }
        guard pts.count >= 3, length > snapR * 0.8 else {
            if let p = pts.first { selectPath(at: p, plane: plane, snapR: snapR) }
            return
        }
        // Endpoints near the centre axis snap onto it (half profiles revolve cleanly).
        if abs(pts[0].x) < snapR * 0.8 { pts[0].x = 0 }
        if abs(pts[pts.count - 1].x) < snapR * 0.8 { pts[pts.count - 1].x = 0 }
        let closed = simd_distance(pts[0], pts[pts.count - 1]) < snapR * 1.5 && length > snapR * 6

        var replaced: UUID?
        if !closed, let s = timeline.sketch(plane) {
            // Continue an open curve whose end is near this stroke's start (or vice versa).
            for path in s.paths where !path.closed && path.anchors.count >= 2 {
                let poly = path.polyline(samplesPerSegment: 16)
                guard let a = poly.first, let b = poly.last else { continue }
                if simd_distance(b, pts[0]) < snapR { pts = poly + pts; replaced = path.id; break }
                if simd_distance(a, pts[pts.count - 1]) < snapR { pts = pts + poly; replaced = path.id; break }
                if simd_distance(a, pts[0]) < snapR { pts = poly.reversed() + pts; replaced = path.id; break }
                if simd_distance(b, pts[pts.count - 1]) < snapR { pts = poly + pts.reversed(); replaced = path.id; break }
            }
        }
        let nowClosed = closed || (replaced != nil && simd_distance(pts[0], pts[pts.count - 1]) < snapR * 1.5)
        var opts = BezierFitter.Options()
        opts.tolerance = clamp(snapR * 0.12, 0.25, 2.5)
        opts.minSpacing = clamp(snapR * 0.05, 0.2, 1.5)
        let segs = BezierFitter.fit(pts, closed: nowClosed, options: opts)
        guard !segs.isEmpty else { return }
        var path = SketchPath(segments: segs, closed: nowClosed, kind: .freehand)

        // Tutorial: a trace close to the guide snaps onto it ("the curve snaps smooth").
        if let ghost = tutorial?.ghost(for: plane), let gb = Optional(ghost.bounds), let pb = Optional(path.bounds),
           (pb.max.y - pb.min.y) > (gb.max.y - gb.min.y) * 0.6 {
            let samples = path.polyline(samplesPerSegment: 6)
            let mean = samples.reduce(Float(0)) { $0 + ghost.distance(to: $1) } / Float(max(samples.count, 1))
            if mean < 9 {
                path = ghost
                path.id = UUID()
                showToast("Snapped smooth to the guide", symbol: "sparkles")
            }
        }
        let newPath = path
        commit { tl in tl.editSketch(plane) { s in
            if let r = replaced, let i = s.pathIndex(r) { s.paths.remove(at: i) }
            s.paths.append(newPath)
        } }
        sketchSelection = SketchSelection(plane: plane, pathID: newPath.id)
        hapticTick += 1
        tutorial?.handle(.sketchCommitted(plane), in: self)
    }

    // MARK: Shapes

    public func finishPolyline(closed: Bool) {
        let pts = livePolyline
        livePolyline = []
        guard pts.count >= 2 else { return }
        addPath(.polyline(pts, closed: closed), plane: livePlane)
    }

    func addPath(_ path: SketchPath, plane: SketchPlane) {
        commit { $0.editSketch(plane) { $0.paths.append(path) } }
        sketchSelection = SketchSelection(plane: plane, pathID: path.id)
        hapticTick += 1
        tutorial?.handle(.sketchCommitted(plane), in: self)
    }

    /// Replaces a plane's sketch with the tutorial guide ("Show me").
    public func applyGuideSketch(_ plane: SketchPlane, notify: Bool = true) {
        let path = plane == .side ? VaseGuide.silhouette(depthScale: 0.86) : VaseGuide.silhouette()
        commit { $0.editSketch(plane) { $0 = Sketch(paths: [path]) } }
        if mode != .sketch { setMode(.sketch) }
        setPlane(plane)
        hapticTick += 1
        if notify { tutorial?.handle(.sketchCommitted(plane), in: self) }
    }

    private func snapToAxis(_ p: Vec2, _ snapR: Float) -> Vec2 {
        var q = p
        if abs(q.x) < snapR * 0.6 { q.x = 0 }
        if abs(q.y) < snapR * 0.6 { q.y = 0 }
        return q
    }

    private func orthoSnap(_ p: Vec2, from a: Vec2) -> Vec2 {
        abs(p.x - a.x) > abs(p.y - a.y) ? Vec2(p.x, a.y) : Vec2(a.x, p.y)
    }

    private func squareSnap(_ a: Vec2, _ p: Vec2) -> Vec2 {
        let d = p - a
        let m = max(abs(d.x), abs(d.y))
        return a + Vec2(copysign(m, d.x), copysign(m, d.y))
    }

    // MARK: Edit tool

    private func hitAnchor(_ p: Vec2, plane: SketchPlane, snapR: Float) -> (UUID, Int, AnchorPart)? {
        guard let s = timeline.sketch(plane) else { return nil }
        if let sel = sketchSelection, sel.plane == plane, let path = s.paths.first(where: { $0.id == sel.pathID }) {
            for (i, a) in path.anchors.enumerated() {
                if a.inHandle != .zero, simd_distance(a.position + a.inHandle, p) < snapR { return (path.id, i, .inHandle) }
                if a.outHandle != .zero, simd_distance(a.position + a.outHandle, p) < snapR { return (path.id, i, .outHandle) }
            }
        }
        var best: (UUID, Int, AnchorPart)?
        var bestD = snapR
        for path in s.paths {
            for (i, a) in path.anchors.enumerated() {
                let d = simd_distance(a.position, p)
                if d < bestD { bestD = d; best = (path.id, i, .point) }
            }
        }
        return best
    }

    private func pathAt(_ p: Vec2, plane: SketchPlane, snapR: Float) -> SketchPath? {
        timeline.sketch(plane)?.paths.min { $0.distance(to: p) < $1.distance(to: p) }.flatMap { $0.distance(to: p) < snapR ? $0 : nil }
    }

    private func selectPath(at p: Vec2, plane: SketchPlane, snapR: Float) {
        if let path = pathAt(p, plane: plane, snapR: snapR) {
            sketchSelection = SketchSelection(plane: plane, pathID: path.id)
        } else {
            sketchSelection = nil
        }
    }

    private func editDown(_ p: Vec2, plane: SketchPlane, snapR: Float, modifiers: KeyModifiers) {
        if let (pid, idx, part) = hitAnchor(p, plane: plane, snapR: snapR) {
            if part == .point {
                if modifiers.contains(.option) { toggleCorner(plane: plane, pid, idx); return }
                if modifiers.contains(.shift), var sel = sketchSelection, sel.plane == plane, sel.pathID == pid {
                    if let k = sel.anchors.firstIndex(of: idx) { sel.anchors.remove(at: k) } else { sel.anchors.append(idx) }
                    sketchSelection = sel
                    return
                }
                sketchSelection = SketchSelection(plane: plane, pathID: pid, anchors: [idx])
            }
            sketchDrag = .anchor(pathID: pid, index: idx, part: part, started: false)
        } else if let path = pathAt(p, plane: plane, snapR: snapR) {
            sketchSelection = SketchSelection(plane: plane, pathID: path.id)
            sketchDrag = .path(pathID: path.id, last: p, started: false)
        } else {
            sketchSelection = nil
        }
    }

    private func moveAnchor(plane: SketchPlane, _ pid: UUID, _ idx: Int, _ part: AnchorPart, to p: Vec2) {
        liveChange { $0.editSketch(plane) { s in
            guard let i = s.pathIndex(pid), idx < s.paths[i].anchors.count else { return }
            var a = s.paths[i].anchors[idx]
            let smooth = !a.isCorner
            switch part {
            case .point:
                a.position = p
            case .inHandle:
                a.inHandle = p - a.position
                if smooth { a.outHandle = -a.inHandle.safeNormalized * simd_length(a.outHandle) }
            case .outHandle:
                a.outHandle = p - a.position
                if smooth { a.inHandle = -a.outHandle.safeNormalized * simd_length(a.inHandle) }
            }
            s.paths[i].anchors[idx] = a
            if s.paths[i].kind == .circle || s.paths[i].kind == .rectangle { s.paths[i].kind = .freehand }
        } }
    }

    private func toggleCorner(plane: SketchPlane, _ pid: UUID, _ idx: Int) {
        commit { $0.editSketch(plane) { s in
            guard let i = s.pathIndex(pid) else { return }
            let path = s.paths[i]
            var a = path.anchors[idx]
            if a.isCorner {
                // Make smooth: handles along the neighbour direction.
                let n = path.anchors.count
                let prev = path.anchors[(idx - 1 + n) % n].position, next = path.anchors[(idx + 1) % n].position
                let dir = (next - prev).safeNormalized
                let len = simd_distance(prev, next) / 6
                a.inHandle = -dir * len; a.outHandle = dir * len
            } else {
                a.inHandle = .zero; a.outHandle = .zero
            }
            s.paths[i].anchors[idx] = a
        } }
    }

    // MARK: Eraser

    private func erase(at p: Vec2, plane: SketchPlane, snapR: Float) {
        guard let path = pathAt(p, plane: plane, snapR: snapR) else { return }
        if case .erase(false)? = sketchDrag { pushUndo(); sketchDrag = .erase(started: true) }
        liveChange { $0.editSketch(plane) { s in
            s.paths.removeAll { $0.id == path.id }
            s.constraints.removeAll { c in c.anchorRefs.contains { $0.path == path.id } || c.circlePaths.contains(path.id) }
        } }
        if sketchSelection?.pathID == path.id { sketchSelection = nil }
    }

    // MARK: Constraints

    private func dimensionDown(_ p: Vec2, plane: SketchPlane, snapR: Float) {
        if let (pid, idx, part) = hitAnchor(p, plane: plane, snapR: snapR), part == .point {
            let ref = AnchorRef(path: pid, index: idx)
            if pendingDimensionAnchors.contains(ref) { return }
            pendingDimensionAnchors.append(ref)
            if pendingDimensionAnchors.count == 2, let s = timeline.sketch(plane) {
                let a = pendingDimensionAnchors[0], b = pendingDimensionAnchors[1]
                pendingDimensionAnchors = []
                guard let pa = position(a, in: s), let pb = position(b, in: s) else { return }
                addConstraint(.distance(a, b, simd_distance(pa, pb)), plane: plane, edit: true)
            }
        } else if let path = pathAt(p, plane: plane, snapR: snapR), path.kind == .circle {
            let r = path.anchors.map { simd_distance($0.position, path.centroid) }.reduce(0, +) / Float(path.anchors.count)
            addConstraint(.radius(path.id, r), plane: plane, edit: true)
        } else {
            pendingDimensionAnchors = []
        }
    }

    func position(_ r: AnchorRef, in s: Sketch) -> Vec2? {
        guard let i = s.pathIndex(r.path), r.index < s.paths[i].anchors.count else { return nil }
        return s.paths[i].anchors[r.index].position
    }

    public func addConstraint(_ c: SketchConstraint, plane: SketchPlane, edit: Bool = false) {
        commit { $0.editSketch(plane) { s in
            s.constraints.append(c)
            ConstraintSolver.solve(&s)
        } }
        if edit, let n = timeline.sketch(plane)?.constraints.count { editingCallout = .sketchConstraint(plane, n - 1) }
        hapticTick += 1
        showToast("\(c.title) constraint", symbol: c.symbol)
    }

    public func removeConstraint(plane: SketchPlane, at i: Int) {
        commit { $0.editSketch(plane) { s in if i < s.constraints.count { s.constraints.remove(at: i) } } }
    }

    /// Constraints that make sense for the current selection (shown in the inspector).
    public func availableConstraints() -> [SketchConstraint] {
        guard let sel = sketchSelection, let path = sketchPath(sel), let s = timeline.sketch(sel.plane) else { return [] }
        let refs = sel.anchors.map { AnchorRef(path: sel.pathID, index: $0) }
        var out: [SketchConstraint] = []
        if path.kind == .circle && refs.isEmpty {
            let r = path.anchors.map { simd_distance($0.position, path.centroid) }.reduce(0, +) / Float(path.anchors.count)
            out.append(.radius(path.id, r))
        }
        switch refs.count {
        case 1:
            if let p = position(refs[0], in: s) { out.append(.fixed(refs[0], p)) }
            out.append(.tangent(refs[0]))
        case 2:
            let a = refs[0], b = refs[1]
            if let pa = position(a, in: s), let pb = position(b, in: s) {
                out += [.horizontal(a, b), .vertical(a, b), .distance(a, b, simd_distance(pa, pb)),
                        .horizontalDistance(a, b, abs(pb.x - pa.x)), .verticalDistance(a, b, abs(pb.y - pa.y))]
            }
        case 3:
            let (a, b, c) = (refs[0], refs[1], refs[2])
            out.append(.perpendicular(a, b, b, c))
            if let pa = position(a, in: s), let pb = position(b, in: s), let pc = position(c, in: s) {
                let u = (pb - pa).safeNormalized, w = (pc - pb).safeNormalized
                out.append(.angle(a, b, b, c, degrees(abs(atan2(u.cross(w), simd_dot(u, w))))))
            }
        case 4:
            out += [.parallel(refs[0], refs[1], refs[2], refs[3]), .perpendicular(refs[0], refs[1], refs[2], refs[3]),
                    .equalLength(refs[0], refs[1], refs[2], refs[3])]
        default:
            break
        }
        return out
    }

    /// Stretches the side sketch so its base and top line up with the front.
    public func matchSideHeight() {
        guard let front = timeline.sketch(.front), var side = timeline.sketch(.side) else { return }
        SilhouetteMatcher.matchHeights(front: front, side: &side)
        commit { $0.editSketch(.side) { $0 = side } }
        showToast("Side height matched to front", symbol: "arrow.up.and.down")
    }

    // MARK: Cover

    public func saveCover(_ c: ProjectCover) {
        document.cover = c
        coverEditorPresented = false
        saveNow()
        tutorial?.handle(.coverSaved, in: self)
    }
}
