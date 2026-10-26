import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Events

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1)
    public static let control = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)
}

public struct PointerEvent: Sendable {
    public enum Phase: Sendable { case down, dragged, up, moved, cancelled, exited }
    public enum Button: Sendable { case primary, secondary, middle }
    public enum Device: Sendable { case mouse, finger, pencil }
    public var phase: Phase
    public var button: Button = .primary
    public var device: Device = .mouse
    public var location: CGPoint
    /// 0…1 (mouse buttons report 1).
    public var pressure: Float = 1
    public var modifiers: KeyModifiers = []
    public var clickCount = 1
    public init(phase: Phase, location: CGPoint) { self.phase = phase; self.location = location }
}

public struct ScrollEvent: Sendable {
    public var location: CGPoint
    public var delta: CGSize
    /// Trackpad / Magic Mouse (smooth deltas) as opposed to a notched wheel.
    public var precise: Bool
    public var modifiers: KeyModifiers
}

/// Callbacks from a pointer capture surface.
public struct PointerHandlers {
    public var pointer: (PointerEvent) -> Void = { _ in }
    public var scroll: (ScrollEvent) -> Void = { _ in }
    public var magnify: (CGFloat, CGPoint) -> Void = { _, _ in }
    public var twoFingerPan: (CGSize) -> Void = { _ in }
    public var multiTap: (Int) -> Void = { _ in }
    public var pencilDoubleTap: () -> Void = {}
    public var resized: (CGSize) -> Void = { _ in }
    public init() {}
}

// MARK: - macOS

#if os(macOS)
/// Transparent view that turns AppKit mouse, tablet, trackpad and wheel events into `PointerEvent`s.
public final class PointerCaptureView: NSView {
    public var handlers = PointerHandlers()
    private var tracking: NSTrackingArea?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        handlers.resized(newSize)
    }

    private func modifiers(_ f: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.command) { m.insert(.command) }
        return m
    }

    private func send(_ e: NSEvent, _ phase: PointerEvent.Phase, _ button: PointerEvent.Button) {
        let isTablet = e.subtype == .tabletPoint
        var ev = PointerEvent(phase: phase, location: convert(e.locationInWindow, from: nil))
        ev.button = button
        ev.device = isTablet ? .pencil : .mouse
        ev.pressure = isTablet ? max(0.05, e.pressure) : 1
        ev.modifiers = modifiers(e.modifierFlags)
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(e.type) { ev.clickCount = e.clickCount }
        handlers.pointer(ev)
    }

    public override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); send(e, .down, .primary) }
    public override func mouseDragged(with e: NSEvent) { send(e, .dragged, .primary) }
    public override func mouseUp(with e: NSEvent) { send(e, .up, .primary) }
    public override func rightMouseDown(with e: NSEvent) { send(e, .down, .secondary) }
    public override func rightMouseDragged(with e: NSEvent) { send(e, .dragged, .secondary) }
    public override func rightMouseUp(with e: NSEvent) { send(e, .up, .secondary) }
    public override func otherMouseDown(with e: NSEvent) { send(e, .down, .middle) }
    public override func otherMouseDragged(with e: NSEvent) { send(e, .dragged, .middle) }
    public override func otherMouseUp(with e: NSEvent) { send(e, .up, .middle) }
    public override func mouseMoved(with e: NSEvent) { send(e, .moved, .primary) }
    public override func mouseExited(with e: NSEvent) { send(e, .exited, .primary) }

    public override func scrollWheel(with e: NSEvent) {
        handlers.scroll(ScrollEvent(location: convert(e.locationInWindow, from: nil),
                                    delta: CGSize(width: e.scrollingDeltaX, height: e.scrollingDeltaY),
                                    precise: e.hasPreciseScrollingDeltas, modifiers: modifiers(e.modifierFlags)))
    }

    public override func magnify(with e: NSEvent) {
        handlers.magnify(1 + e.magnification, convert(e.locationInWindow, from: nil))
    }
}

public struct PointerCaptureLayer: NSViewRepresentable {
    var handlers: PointerHandlers
    public init(handlers: PointerHandlers) { self.handlers = handlers }
    public func makeNSView(context: Context) -> PointerCaptureView {
        let v = PointerCaptureView()
        v.handlers = handlers
        return v
    }
    public func updateNSView(_ v: PointerCaptureView, context: Context) { v.handlers = handlers }
}

#else

// MARK: - iPadOS

/// Touch surface: Pencil draws/sculpts with pressure, one finger orbits (or draws until a Pencil
/// has been seen), two fingers pan and pinch, two/three-finger taps undo/redo, Pencil
/// double-tap toggles the eraser/smooth brush.
public final class PointerCaptureView: UIView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    public var handlers = PointerHandlers()
    private weak var activeTouch: UITouch?
    private var lastPinchScale: CGFloat = 1
    private var lastPan: CGPoint = .zero

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.delegate = self
        addGestureRecognizer(pan)
        for n in [2, 3] {
            let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
            tap.numberOfTouchesRequired = n
            tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            tap.delegate = self
            addGestureRecognizer(tap)
        }
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        addGestureRecognizer(hover)
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        handlers.resized(bounds.size)
    }

    private func event(_ t: UITouch, _ phase: PointerEvent.Phase, location: CGPoint? = nil, force: CGFloat? = nil) -> PointerEvent {
        var e = PointerEvent(phase: phase, location: location ?? t.location(in: self))
        e.device = t.type == .pencil ? .pencil : .finger
        if t.type == .pencil {
            let f = force ?? t.force
            e.pressure = Float(max(0.05, min(1, f / max(t.maximumPossibleForce, 0.001))))
        }
        e.clickCount = t.tapCount
        return e
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with ev: UIEvent?) {
        let all = ev?.allTouches?.count ?? touches.count
        if all > 1, let a = activeTouch, a.type != .pencil {
            // A second finger landed: hand over to pinch/pan.
            handlers.pointer(event(a, .cancelled))
            activeTouch = nil
            return
        }
        guard activeTouch == nil, let t = touches.first else { return }
        activeTouch = t
        handlers.pointer(event(t, .down))
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with ev: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        for c in ev?.coalescedTouches(for: t) ?? [t] {
            handlers.pointer(event(t, .dragged, location: c.location(in: self), force: c.force))
        }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with ev: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        handlers.pointer(event(t, .up))
        activeTouch = nil
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with ev: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        handlers.pointer(event(t, .cancelled))
        activeTouch = nil
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { lastPinchScale = 1 }
        guard g.state == .changed else { return }
        handlers.magnify(g.scale / lastPinchScale, g.location(in: self))
        lastPinchScale = g.scale
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        if g.state == .began { lastPan = .zero }
        guard g.state == .changed else { return }
        let t = g.translation(in: self)
        handlers.twoFingerPan(CGSize(width: t.x - lastPan.x, height: t.y - lastPan.y))
        lastPan = t
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        handlers.multiTap(g.numberOfTouchesRequired)
    }

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        var e = PointerEvent(phase: g.state == .ended || g.state == .cancelled ? .exited : .moved, location: g.location(in: self))
        e.device = .pencil
        handlers.pointer(e)
    }

    public func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        handlers.pencilDoubleTap()
    }

    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

public struct PointerCaptureLayer: UIViewRepresentable {
    var handlers: PointerHandlers
    public init(handlers: PointerHandlers) { self.handlers = handlers }
    public func makeUIView(context: Context) -> PointerCaptureView {
        let v = PointerCaptureView()
        v.handlers = handlers
        return v
    }
    public func updateUIView(_ v: PointerCaptureView, context: Context) { v.handlers = handlers }
}
#endif
