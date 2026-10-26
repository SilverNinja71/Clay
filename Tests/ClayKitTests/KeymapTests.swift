import Testing
import Foundation
import CoreGraphics
import simd
@testable import ClayKit

@Suite("Keyboard")
struct KeymapTests {
    func resolve(_ k: KeyStroke, _ mode: WorkspaceMode, modal: Bool = false, numpad: Bool = true) -> KeyCommand? {
        BlenderKeymap.resolve(k, KeymapContext(mode: mode, modalActive: modal, emulateNumpad: numpad))
    }

    @Test func blenderBasics() {
        #expect(resolve(.char("g"), .model) == .grab)
        #expect(resolve(.char("r"), .model) == .rotate)
        #expect(resolve(.char("s"), .model) == .scale)
        #expect(resolve(.char("e"), .model) == .extrude)
        #expect(resolve(.char("d", shift: true), .model) == .duplicate)
        #expect(resolve(.char("x"), .model) == .delete)
        #expect(resolve(KeyStroke(.tab), .model) == .nextMode)
        #expect(resolve(KeyStroke(.tab, shift: true), .model) == .previousMode)
        #expect(resolve(KeyStroke(.character("z"), command: true), .sculpt) == .undo)
        #expect(resolve(KeyStroke(.character("z"), shift: true, command: true), .sketch) == .redo)
    }

    @Test func numpadViews() {
        #expect(resolve(.char("1", numpad: true), .model) == .view(.front))
        #expect(resolve(.char("3", control: true, numpad: true), .model) == .view(.left))
        #expect(resolve(.char("7", numpad: true), .model) == .view(.top))
        #expect(resolve(.char("5", numpad: true), .model) == .toggleOrtho)
        // Top-row digits only act as a numpad when emulation is on.
        #expect(resolve(.char("1"), .model, numpad: true) == .view(.front))
        #expect(resolve(.char("1"), .model, numpad: false) == nil)
    }

    @Test func sculptHotkeysChooseBrushes() {
        #expect(resolve(.char("g"), .sculpt) == .brush(.grab))
        #expect(resolve(.char("s"), .sculpt) == .brush(.smooth))
        #expect(resolve(.char("c"), .sculpt) == .brush(.clay))
        #expect(resolve(.char("c", shift: true), .sculpt) == .brush(.clayStrips))
        #expect(resolve(.char("]"), .sculpt) == .radius(bigger: true))
    }

    @Test func modalKeys() {
        #expect(resolve(.char("x"), .model, modal: true) == .modalAxis(0, plane: false))
        #expect(resolve(.char("z", shift: true), .model, modal: true) == .modalAxis(2, plane: true))
        #expect(resolve(.char("5"), .model, modal: true) == .modalInput("5"))
        #expect(resolve(KeyStroke(.enter), .model, modal: true) == .modalConfirm)
        #expect(resolve(KeyStroke(.escape), .model, modal: true) == .modalCancel)
    }

    @Test func modalTransformNumericInput() {
        var m = ModalTransform(kind: .grab, target: .body, pivot: Vec3(0, 60, 0), pointer: CGPoint(x: 100, y: 100))
        m.setAxis(1, plane: false)
        for c in "12.5" { m.type(c) }
        m.type("-")
        let t = m.transform3D(camera: OrbitCamera(), size: CGSize(width: 800, height: 600))
        #expect(simd_distance(t.translation, Vec3(0, -12.5, 0)) < 1e-4)

        var s = ModalTransform(kind: .scale, target: .body, pivot: .zero, pointer: .zero)
        s.setAxis(0, plane: false)
        s.type("2")
        #expect(s.transform3D(camera: OrbitCamera(), size: CGSize(width: 800, height: 600)).scale == Vec3(2, 1, 1))
    }

    @Test func crc32MatchesReference() {
        #expect(USDZPackager.crc32(Data("123456789".utf8)) == 0xCBF43926)
    }
}
