import Foundation
import CoreGraphics
import simd
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import SwiftUI
#endif

// MARK: - Platform-neutral key strokes

public struct KeyStroke: Equatable, Sendable {
    public enum Key: Equatable, Sendable {
        case character(Character)
        case tab, escape, enter, backspace, forwardDelete, home, space, left, right, up, down
    }
    public var key: Key
    public var shift = false
    public var control = false
    public var option = false
    public var command = false
    /// The key came from the numeric keypad.
    public var numpad = false

    public init(_ key: Key, shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false, numpad: Bool = false) {
        self.key = key; self.shift = shift; self.control = control; self.option = option; self.command = command; self.numpad = numpad
    }

    public static func char(_ c: Character, shift: Bool = false, control: Bool = false, command: Bool = false, numpad: Bool = false) -> KeyStroke {
        KeyStroke(.character(c), shift: shift, control: control, command: command, numpad: numpad)
    }

    var char: Character? {
        if case .character(let c) = key { return c }
        return nil
    }
}

// MARK: - Commands

public enum KeyCommand: Equatable, Sendable {
    case view(ViewPreset), toggleOrtho, frameAll
    case grab, rotate, scale, extrude, duplicate, delete
    case nextMode, previousMode
    case undo, redo, save, export
    case modalAxis(Int, plane: Bool), modalInput(Character), modalBackspace, modalConfirm, modalCancel
    case modalSwitch(ModalTransform.Kind)
    case brush(BrushKind), radius(bigger: Bool), strength(stronger: Bool), toggleSymmetry, remesh
    case toggleWireframe, toggleInspector
    case sketchTool(SketchTool), finishShape
    case measureTool
    case cancel
}

public struct KeymapContext: Sendable {
    public var mode: WorkspaceMode
    public var modalActive: Bool
    public var emulateNumpad: Bool
    public var closedPathSelected: Bool
    public init(mode: WorkspaceMode, modalActive: Bool = false, emulateNumpad: Bool = true, closedPathSelected: Bool = false) {
        self.mode = mode; self.modalActive = modalActive; self.emulateNumpad = emulateNumpad; self.closedPathSelected = closedPathSelected
    }
}

/// Blender-flavoured hotkeys, as a pure function so it can be unit-tested.
public enum BlenderKeymap {

    public static func resolve(_ k: KeyStroke, _ ctx: KeymapContext) -> KeyCommand? {
        let accel = k.command || k.control
        if accel, let c = k.char {
            switch c {
            case "z": return k.shift ? .redo : .undo
            case "y": return .redo
            case "s": return .save
            case "e": return .export
            case "r" where ctx.mode == .sculpt: return .remesh
            default: break
            }
        }
        if ctx.modalActive { return modal(k) }

        switch k.key {
        case .tab: return k.shift ? .previousMode : .nextMode
        case .home: return .frameAll
        case .escape: return .cancel
        case .enter: return ctx.mode == .sketch ? .finishShape : nil
        case .backspace, .forwardDelete: return .delete
        default: break
        }
        if let v = viewCommand(k, ctx) { return v }
        guard let c = k.char, !k.command, !k.option else { return nil }

        switch ctx.mode {
        case .model:
            switch (c, k.shift) {
            case ("g", false): return .grab
            case ("r", false): return .rotate
            case ("s", false): return .scale
            case ("e", false): return .extrude
            case ("d", true): return .duplicate
            case ("x", false): return .delete
            case ("w", false): return .toggleWireframe
            case ("n", false): return .toggleInspector
            default: return nil
            }
        case .sculpt:
            switch (c, k.shift) {
            case ("[", false): return .radius(bigger: false)
            case ("]", false): return .radius(bigger: true)
            case ("[", true), ("{", _): return .strength(stronger: false)
            case ("]", true), ("}", _): return .strength(stronger: true)
            case ("m", false): return .toggleSymmetry
            case ("w", false): return .toggleWireframe
            case ("n", false): return .toggleInspector
            default: break
            }
            for b in BrushKind.allCases where hotkeyMatches(b.hotkey, c, k.shift) { return .brush(b) }
            return nil
        case .sketch:
            switch (c, k.shift) {
            case ("p", false): return .sketchTool(.pencil)
            case ("p", true): return .sketchTool(.pen)
            case ("l", false): return .sketchTool(.line)
            case ("c", false): return .sketchTool(.circle)
            case ("b", false): return .sketchTool(.rectangle)
            case ("v", false): return .sketchTool(.edit)
            case ("d", false): return .sketchTool(.dimension)
            case ("e", false): return ctx.closedPathSelected ? .extrude : .sketchTool(.eraser)
            case ("g", false): return .grab
            case ("r", false): return .rotate
            case ("s", false): return .scale
            case ("d", true): return .duplicate
            case ("x", false): return .delete
            case ("n", false): return .toggleInspector
            default: return nil
            }
        case .dimension:
            switch (c, k.shift) {
            case ("m", false): return .measureTool
            case ("x", false): return .delete
            case ("n", false): return .toggleInspector
            default: return nil
            }
        }
    }

    /// Numpad 1/3/7 views (Ctrl for the opposite side), 5 ortho toggle, "." frame.
    /// With "emulate numpad" the top-row digits do the same, as in Blender's preference.
    static func viewCommand(_ k: KeyStroke, _ ctx: KeymapContext) -> KeyCommand? {
        guard let c = k.char, k.numpad || (ctx.emulateNumpad && !k.shift && !k.command) else { return nil }
        switch c {
        case "1": return .view(k.control ? .back : .front)
        case "3": return .view(k.control ? .left : .right)
        case "7": return .view(k.control ? .bottom : .top)
        case "5": return .toggleOrtho
        case "0": return .view(.threeQuarter)
        case ".": return k.numpad ? .frameAll : nil
        default: return nil
        }
    }

    static func modal(_ k: KeyStroke) -> KeyCommand? {
        switch k.key {
        case .escape: return .modalCancel
        case .enter, .space: return .modalConfirm
        case .backspace, .forwardDelete: return .modalBackspace
        case .character(let c):
            switch c {
            case "x": return .modalAxis(0, plane: k.shift)
            case "y": return .modalAxis(1, plane: k.shift)
            case "z": return .modalAxis(2, plane: k.shift)
            case "g": return .modalSwitch(.grab)
            case "r": return .modalSwitch(.rotate)
            case "s": return .modalSwitch(.scale)
            case "-", ".", ",": return .modalInput(c == "," ? "." : c)
            default: return c.isNumber ? .modalInput(c) : nil
            }
        default: return nil
        }
    }

    static func hotkeyMatches(_ hotkey: String, _ c: Character, _ shift: Bool) -> Bool {
        let wantsShift = hotkey.hasPrefix("⇧")
        guard let last = hotkey.last else { return false }
        return wantsShift == shift && Character(last.lowercased()) == c
    }
}

// MARK: - Modal transform (G / R / S)

/// Blender-style modal transform: press G, R or S, move the pointer, optionally type an axis
/// (X/Y/Z, Shift = plane lock) and a number, then confirm (Enter / click) or cancel (Esc / right click).
public struct ModalTransform: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case grab, rotate, scale
        public var title: String {
            switch self { case .grab: "Move"; case .rotate: "Rotate"; case .scale: "Scale" }
        }
    }
    public enum Constraint: Equatable, Sendable { case free, axis(Int), plane(Int) }
    public enum Target: Equatable, Sendable {
        case body
        case duplicate(UUID)
        case sketchPath(SketchPlane, UUID)
    }

    public var kind: Kind
    public var target: Target
    public var constraint: Constraint = .free
    public var numeric = ""
    public var pivot: Vec3
    public var startPointer: CGPoint
    public var pointer: CGPoint

    public init(kind: Kind, target: Target, pivot: Vec3, pointer: CGPoint) {
        self.kind = kind; self.target = target; self.pivot = pivot
        self.startPointer = pointer; self.pointer = pointer
    }

    public mutating func setAxis(_ a: Int, plane: Bool) {
        let c: Constraint = plane ? .plane(a) : .axis(a)
        constraint = constraint == c ? .free : c
    }

    public mutating func type(_ c: Character) {
        if c == "-" {
            numeric = numeric.hasPrefix("-") ? String(numeric.dropFirst()) : "-" + numeric
        } else if c != "." || !numeric.contains(".") {
            numeric.append(c)
        }
    }

    public mutating func backspace() { if !numeric.isEmpty { numeric.removeLast() } }

    public var numericValue: Float? {
        let s = numeric == "-" ? "" : numeric
        return s.isEmpty ? nil : Float(s)
    }

    static func unit(_ a: Int) -> Vec3 { a == 0 ? Vec3(1, 0, 0) : (a == 1 ? Vec3(0, 1, 0) : Vec3(0, 0, 1)) }

    /// Closest-point parameter on the line `p + d·t` to a ray.
    static func lineParameter(_ p: Vec3, _ d: Vec3, _ ray: Ray) -> Float? {
        let w = p - ray.origin
        let b = simd_dot(d, ray.direction)
        let denom = 1 - b * b
        guard abs(denom) > 1e-5 else { return nil }
        return (b * simd_dot(ray.direction, w) - simd_dot(d, w)) / denom
    }

    // MARK: 3D

    public func transform3D(camera: OrbitCamera, size: CGSize) -> TransformParameters {
        var t = TransformParameters()
        t.pivot = pivot
        let n = numericValue
        switch kind {
        case .grab:
            let r0 = camera.ray(at: startPointer, in: size), r1 = camera.ray(at: pointer, in: size)
            switch constraint {
            case .axis(let a):
                let axis = Self.unit(a)
                if let n { t.translation = axis * n }
                else if let t0 = Self.lineParameter(pivot, axis, r0), let t1 = Self.lineParameter(pivot, axis, r1) {
                    t.translation = axis * (t1 - t0)
                }
            case .plane(let a):
                let normal = Self.unit(a)
                if let n { t.translation = Self.unit((a + 1) % 3) * n }
                else if let p0 = r0.intersectPlane(point: pivot, normal: normal) ?? r0.intersectPlane(point: pivot, normal: -normal),
                        let p1 = r1.intersectPlane(point: pivot, normal: normal) ?? r1.intersectPlane(point: pivot, normal: -normal) {
                    var d = p1 - p0; d[a] = 0
                    t.translation = d
                }
            case .free:
                if let n { t.translation = Vec3(n, 0, 0) }
                else if let p0 = r0.intersectPlane(point: pivot, normal: -camera.forward),
                        let p1 = r1.intersectPlane(point: pivot, normal: -camera.forward) {
                    t.translation = p1 - p0
                }
            }
        case .rotate:
            var axis = -camera.forward
            if case .axis(let a) = constraint { axis = Self.unit(a) }
            if case .plane(let a) = constraint { axis = Self.unit(a) }
            t.rotationAxis = axis
            if let n {
                t.rotationDegrees = n
            } else if let ps = camera.project(pivot, in: size) {
                let a0 = atan2(Float(startPointer.y - ps.y), Float(startPointer.x - ps.x))
                let a1 = atan2(Float(pointer.y - ps.y), Float(pointer.x - ps.x))
                // Screen y points down, so a positive screen angle is clockwise.
                var deg = -degrees(angleDelta(a0, a1))
                if simd_dot(axis, -camera.forward) < 0 { deg = -deg }
                t.rotationDegrees = deg
            }
        case .scale:
            var f: Float = 1
            if let n { f = n }
            else if let ps = camera.project(pivot, in: size) {
                let d0 = hypot(Float(startPointer.x - ps.x), Float(startPointer.y - ps.y))
                let d1 = hypot(Float(pointer.x - ps.x), Float(pointer.y - ps.y))
                f = d0 > 2 ? d1 / d0 : 1
            }
            switch constraint {
            case .free: t.scale = Vec3(repeating: f)
            case .axis(let a): var s = Vec3(repeating: 1); s[a] = f; t.scale = s
            case .plane(let a): var s = Vec3(repeating: f); s[a] = 1; t.scale = s
            }
        }
        return t
    }

    // MARK: 2D (sketch paths)

    /// Point map for a sketch-plane transform. `pivot2D` is the path centre on the plane.
    public func transform2D(pivot2D: Vec2, view: SketchViewTransform, size: CGSize) -> (Vec2) -> Vec2 {
        let p0 = view.toPlane(startPointer, size: size), p1 = view.toPlane(pointer, size: size)
        let n = numericValue
        var axis2 = -1
        if case .axis(let a) = constraint { axis2 = a }
        switch kind {
        case .grab:
            var d = p1 - p0
            if let n { d = axis2 == 1 ? Vec2(0, n) : Vec2(n, 0) }
            else if axis2 == 0 { d.y = 0 } else if axis2 == 1 { d.x = 0 }
            return { $0 + d }
        case .rotate:
            let ang: Float
            if let n { ang = radians(n) }
            else {
                let v0 = p0 - pivot2D, v1 = p1 - pivot2D
                ang = angleDelta(atan2(v0.y, v0.x), atan2(v1.y, v1.x))
            }
            let c = cos(ang), s = sin(ang)
            return { p in
                let v = p - pivot2D
                return pivot2D + Vec2(v.x * c - v.y * s, v.x * s + v.y * c)
            }
        case .scale:
            var f: Float = 1
            if let n { f = n } else {
                let d0 = simd_distance(p0, pivot2D)
                f = d0 > 0.5 ? simd_distance(p1, pivot2D) / d0 : 1
            }
            let s = Vec2(axis2 == 1 ? 1 : f, axis2 == 0 ? 1 : f)
            return { pivot2D + ($0 - pivot2D) * s }
        }
    }

    /// Status-bar text, e.g. "Move · X  12.5 mm".
    public func describe(_ t: TransformParameters, units: LengthUnit) -> String {
        let axisName = ["X", "Y", "Z"]
        var c = ""
        switch constraint {
        case .free: c = ""
        case .axis(let a): c = " · \(axisName[a])"
        case .plane(let a): c = " · plane ⟂\(axisName[a])"
        }
        let typed = numeric.isEmpty ? "" : "  [\(numeric)]"
        switch kind {
        case .grab:
            let d = t.translation
            return "Move\(c)  Δ \(units.format(d.x, withSymbol: false)), \(units.format(d.y, withSymbol: false)), \(units.format(d.z, withSymbol: false)) \(units.symbol)\(typed)"
        case .rotate:
            return "Rotate\(c)  \(String(format: "%.1f", t.rotationDegrees))°\(typed)"
        case .scale:
            let s = t.scale
            return "Scale\(c)  \(String(format: "%.3f", max(s.x, s.y, s.z) == 1 ? min(s.x, s.y, s.z) : max(s.x, s.y, s.z)))×\(typed)"
        }
    }
}

// MARK: - macOS event monitor

#if os(macOS)
/// Installs an app-wide key monitor while the workspace is open. Keys typed into text fields
/// are left alone.
@MainActor
public final class KeyboardShortcutManager {
    private var monitor: Any?
    public var handler: ((KeyStroke) -> Bool)?

    public init() {}

    public func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.window?.firstResponder is NSText { return event }
            guard let stroke = KeyStroke(event: event) else { return event }
            let handled = MainActor.assumeIsolated { self?.handler?(stroke) ?? false }
            return handled ? nil : event
        }
    }

    public func uninstall() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

extension KeyStroke {
    static let numpadCodes: [UInt16: Character] = [
        0x52: "0", 0x53: "1", 0x54: "2", 0x55: "3", 0x56: "4", 0x57: "5", 0x58: "6",
        0x59: "7", 0x5B: "8", 0x5C: "9", 0x41: ".", 0x45: "+", 0x4E: "-",
    ]

    init?(event e: NSEvent) {
        let f = e.modifierFlags
        func make(_ key: Key, numpad: Bool = false) -> KeyStroke {
            KeyStroke(key, shift: f.contains(.shift), control: f.contains(.control), option: f.contains(.option),
                      command: f.contains(.command), numpad: numpad)
        }
        switch e.keyCode {
        case 0x30: self = make(.tab)
        case 0x35: self = make(.escape)
        case 0x24, 0x4C: self = make(.enter)
        case 0x33: self = make(.backspace)
        case 0x75: self = make(.forwardDelete)
        case 0x73: self = make(.home)
        case 0x31: self = make(.space)
        case 0x7B: self = make(.left)
        case 0x7C: self = make(.right)
        case 0x7D: self = make(.down)
        case 0x7E: self = make(.up)
        default:
            if let c = Self.numpadCodes[e.keyCode] { self = make(.character(c), numpad: true); return }
            guard let s = e.charactersIgnoringModifiers?.lowercased(), let c = s.first else { return nil }
            self = make(.character(c))
        }
    }
}
#endif

// MARK: - iPad (hardware keyboard via SwiftUI)

#if os(iOS)
extension KeyStroke {
    init?(press p: KeyPress) {
        let m = p.modifiers
        func make(_ key: Key) -> KeyStroke {
            KeyStroke(key, shift: m.contains(.shift), control: m.contains(.control), option: m.contains(.option),
                      command: m.contains(.command), numpad: m.contains(.numericPad))
        }
        switch p.key {
        case .tab: self = make(.tab)
        case .escape: self = make(.escape)
        case .return: self = make(.enter)
        case .delete: self = make(.backspace)
        case .deleteForward: self = make(.forwardDelete)
        case .home: self = make(.home)
        case .space: self = make(.space)
        case .leftArrow: self = make(.left)
        case .rightArrow: self = make(.right)
        case .upArrow: self = make(.up)
        case .downArrow: self = make(.down)
        default:
            guard let c = p.characters.lowercased().first else { return nil }
            self = make(.character(c))
        }
    }
}
#endif
