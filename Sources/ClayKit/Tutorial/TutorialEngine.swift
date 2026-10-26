import SwiftUI
import Observation

public enum TutorialPhase: Int, CaseIterable, Sendable {
    case welcome, frontSketch, sideSketch, generate, sculpt, smooth, dimension, cover, done
}

public enum TutorialEvent: Sendable {
    case sketchCommitted(SketchPlane)
    case generated
    case stroke(BrushKind)
    case dimensionChanged(ProfileDimension, Float)
    case coverSaved
    case modeChanged(WorkspaceMode)
    case tappedBody
}

/// First-run "Ceramic Vase" walkthrough: a small state machine that watches workspace events,
/// moves the camera/tools for each step, and can perform any step itself ("Show me").
@MainActor @Observable
public final class TutorialEngine {
    public private(set) var phase: TutorialPhase = .welcome
    public var minimized = false
    @ObservationIgnored private var pending: Task<Void, Never>?

    public init() {}

    public static var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "Clay.onboarded") }
        set { UserDefaults.standard.set(newValue, forKey: "Clay.onboarded") }
    }

    // MARK: Copy

    public var stepNumber: Int { max(0, min(phase.rawValue, 7)) }
    public var stepCount: Int { 7 }

    public var title: String {
        switch phase {
        case .welcome: "Make a ceramic vase"
        case .frontSketch: "Front silhouette"
        case .sideSketch: "Side profile"
        case .generate: "Generate 3D Clay"
        case .sculpt: "Sculpt the neck"
        case .smooth: "Smooth it out"
        case .dimension: "Make it precise"
        case .cover: "Pick a cover"
        case .done: "Your first Clay model!"
        }
    }

    public var prompt: String {
        switch phase {
        case .welcome:
            "In five minutes you'll sketch, form, sculpt and dimension a real vase — the whole Clay workflow."
        case .frontSketch:
            "Draw the front silhouette of this vase with your Apple Pencil or cursor. Trace the dashed guide in one stroke and close the loop."
        case .sideSketch:
            "Now the side view. The blue lines carry the base, belly and neck across from your front sketch — trace the slimmer profile."
        case .generate:
            "Both views are ready. Tap Generate 3D Clay and watch the two silhouettes loft into a solid."
        case .sculpt:
            "Push and sculpt details like real pottery clay. Pick the Clay brush (C) and drag across the neck to build a ring."
        case .smooth:
            "Hold Shift while you stroke (or hold the Smooth button) to relax rough spots."
        case .dimension:
            "Tap the base of the vase — its diameter reads 50 mm. Tap the label and change it to 65 mm."
        case .cover:
            "Choose a studio cover for your notebook and save the model to your library."
        case .done:
            "You sketched in 2D, formed in 3D, sculpted like clay and measured with precision. Every step is in the timeline below — click any of them to change it."
        }
    }

    public var hint: String? {
        switch phase {
        case .frontSketch, .sideSketch: "Close to the guide is enough — it snaps smooth."
        case .sculpt: "Hold Ctrl to carve instead of build. [ and ] change the brush size."
        case .dimension: "Typing 6.5 cm or 50 + 15 works too."
        default: nil
        }
    }

    public var symbol: String {
        switch phase {
        case .welcome: "sparkles"
        case .frontSketch, .sideSketch: "pencil.tip"
        case .generate: "cube.transparent"
        case .sculpt: "hand.point.up.left"
        case .smooth: "drop"
        case .dimension: "ruler"
        case .cover: "book.closed"
        case .done: "checkmark.seal.fill"
        }
    }

    public var highlightedCallout: CalloutID? { phase == .dimension ? .profile(.baseWidth) : nil }
    public var highlightsGenerate: Bool { phase == .generate }

    /// The ghosted outline to trace on `plane`, if this step has one.
    public func ghost(for plane: SketchPlane) -> SketchPath? {
        switch (phase, plane) {
        case (.frontSketch, .front): VaseGuide.silhouette()
        case (.sideSketch, .side): VaseGuide.silhouette(depthScale: 0.86)
        default: nil
        }
    }

    // MARK: Flow

    public func start(in s: WorkspaceState) { go(.frontSketch, in: s) }

    public func handle(_ e: TutorialEvent, in s: WorkspaceState) {
        switch (phase, e) {
        case (.frontSketch, .sketchCommitted(.front)):
            if sketchIsComplete(s, .front) { go(.sideSketch, in: s, after: 0.6) }
            else { s.showToast("Keep going — trace the whole outline", symbol: "pencil.tip") }
        case (.sideSketch, .sketchCommitted(.side)):
            if sketchIsComplete(s, .side) { go(.generate, in: s, after: 0.4) }
            else { s.showToast("Keep going — trace the whole profile", symbol: "pencil.tip") }
        case (.generate, .generated):
            go(.sculpt, in: s, after: 1.9)
        case (.sculpt, .stroke(let k)):
            if k == .clay || k == .clayStrips { go(.smooth, in: s, after: 0.3) }
            else if k != .smooth { s.showToast("Nice! Now try the Clay brush (C)", symbol: BrushKind.clay.symbol) }
        case (.smooth, .stroke(.smooth)):
            go(.dimension, in: s, after: 0.4)
        case (.dimension, .dimensionChanged(.baseWidth, let v)):
            if abs(v - 65) < 0.6 { go(.cover, in: s, after: 1.0) }
            else { s.showToast("Now set it to exactly 65 mm", symbol: "ruler") }
        case (.cover, .coverSaved):
            go(.done, in: s)
        default:
            break
        }
    }

    private func sketchIsComplete(_ s: WorkspaceState, _ plane: SketchPlane) -> Bool {
        guard let sk = s.timeline.sketch(plane), let p = SilhouetteProfile(sketch: sk) else { return false }
        return p.height > 70
    }

    func go(_ p: TutorialPhase, in s: WorkspaceState, after delay: Double = 0) {
        pending?.cancel()
        pending = Task { [weak self, weak s] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self, let s else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { self.phase = p }
            self.enter(p, s)
        }
    }

    private func enter(_ p: TutorialPhase, _ s: WorkspaceState) {
        minimized = false
        switch p {
        case .frontSketch:
            s.setMode(.sketch)
            s.splitSketch = false
            s.sketchTool = .pencil
            s.setPlane(.front)
            s.fitSketchView(.front)
        case .sideSketch:
            s.sketchTool = .pencil
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { s.setPlane(.side) }
            s.fitSketchView(.side)
        case .sculpt:
            s.setMode(.sculpt)
        case .dimension:
            s.setMode(.dimension)
        case .cover:
            s.coverEditorPresented = true
        case .done:
            s.successTick += 1
            Self.hasCompletedOnboarding = true
        default:
            break
        }
    }

    /// Performs the current step for the user.
    public func showMe(in s: WorkspaceState) {
        switch phase {
        case .welcome: start(in: s)
        case .frontSketch: s.applyGuideSketch(.front)
        case .sideSketch: s.applyGuideSketch(.side)
        case .generate: s.generateClay()
        case .sculpt: s.brush.kind = .clay; s.demoSculpt()
        case .smooth: s.demoSculpt(smoothOnly: true)
        case .dimension: s.setCallout(.profile(.baseWidth), value: 65)
        case .cover:
            var c = s.document.cover
            c.material = .glazedCeramic
            c.tint = CoverMaterial.glazedCeramic.defaultTint
            c.emblem = "cup.and.saucer.fill"
            s.saveCover(c)
        case .done: finish(in: s)
        }
    }

    public func skip(in s: WorkspaceState) {
        guard let next = TutorialPhase(rawValue: phase.rawValue + 1) else { finish(in: s); return }
        // Skipping a building step still needs its result for the steps after it.
        switch phase {
        case .frontSketch where s.timeline.sketch(.front)?.isEmpty ?? true: s.applyGuideSketch(.front, notify: false)
        case .sideSketch where s.timeline.sketch(.side)?.isEmpty ?? true: s.applyGuideSketch(.side, notify: false)
        case .generate where s.timeline.loftIndex == nil: s.generateClay()
        default: break
        }
        go(next, in: s)
    }

    public func finish(in s: WorkspaceState) {
        Self.hasCompletedOnboarding = true
        pending?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { s.tutorial = nil }
    }
}
