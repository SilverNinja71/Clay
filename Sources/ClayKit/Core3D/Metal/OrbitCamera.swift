import Foundation
import CoreGraphics
import simd

public enum ViewPreset: String, CaseIterable, Sendable {
    case front, back, right, left, top, bottom, threeQuarter

    var angles: (yaw: Float, pitch: Float) {
        switch self {
        case .front: (0, 0)
        case .back: (.pi, 0)
        case .right: (.pi / 2, 0)
        case .left: (-.pi / 2, 0)
        case .top: (0, .pi / 2)
        case .bottom: (0, -.pi / 2)
        case .threeQuarter: (0.62, 0.38)
        }
    }

    public var isOrthographic: Bool { self != .threeQuarter }
}

/// Turntable camera (Y up). yaw 0 / pitch 0 looks at the front (down −Z), like Blender's Numpad 1.
public struct OrbitCamera: Equatable, Codable, Sendable {
    public var target = Vec3(0, 60, 0)
    public var yaw: Float = 0.62
    public var pitch: Float = 0.38
    public var distance: Float = 360
    public var fovY: Float = 0.56
    public var orthographic = false

    public init() {}

    var offsetDirection: Vec3 { Vec3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) }
    public var forward: Vec3 { -offsetDirection }
    public var up: Vec3 { Vec3(-sin(pitch) * sin(yaw), cos(pitch), -sin(pitch) * cos(yaw)) }
    public var right: Vec3 { simd_cross(forward, up).safeNormalized }

    /// Ortho cameras sit far back so nothing near the model is clipped.
    var eyeDistance: Float { orthographic ? max(distance * 4, 3000) : distance }
    public var eye: Vec3 { target + offsetDirection * eyeDistance }

    public var viewMatrix: Mat4 { .lookAt(eye: eye, target: target, up: up) }

    var halfHeight: Float { distance * tan(fovY * 0.5) }

    public func projectionMatrix(aspect: Float) -> Mat4 {
        if orthographic {
            let hh = halfHeight
            return .orthographic(halfWidth: hh * aspect, halfHeight: hh, near: 1, far: eyeDistance * 2 + 4000)
        }
        return .perspective(fovY: fovY, aspect: aspect, near: max(distance * 0.01, 0.5), far: distance * 30 + 4000)
    }

    public func viewProjection(aspect: Float) -> Mat4 { projectionMatrix(aspect: aspect) * viewMatrix }

    /// World units per screen point at the target depth (for panning and dragging).
    public func worldPerPoint(viewHeight: CGFloat) -> Float {
        2 * halfHeight / Float(max(viewHeight, 1))
    }

    /// Ray through a view location (points, top-left origin).
    public func ray(at p: CGPoint, in size: CGSize) -> Ray {
        let aspect = Float(size.width / max(size.height, 1))
        let nx = Float(p.x / max(size.width, 1)) * 2 - 1
        let ny = 1 - Float(p.y / max(size.height, 1)) * 2
        let hh = halfHeight, hw = hh * aspect
        if orthographic {
            let o = target + right * (nx * hw) + up * (ny * hh) - forward * eyeDistance
            return Ray(origin: o, direction: forward)
        }
        let d = forward * distance + right * (nx * hw) + up * (ny * hh)
        return Ray(origin: eye, direction: d)
    }

    /// Projects a world point to view coordinates (points, top-left origin); nil behind the camera.
    public func project(_ w: Vec3, in size: CGSize) -> CGPoint? {
        let aspect = Float(size.width / max(size.height, 1))
        let c = viewProjection(aspect: aspect) * Vec4(w.x, w.y, w.z, 1)
        guard c.w > 1e-5 else { return nil }
        let ndc = Vec2(c.x, c.y) / c.w
        return CGPoint(x: CGFloat((ndc.x + 1) * 0.5) * size.width, y: CGFloat((1 - ndc.y) * 0.5) * size.height)
    }

    // MARK: Navigation

    public mutating func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.008
        pitch = clamp(pitch + dy * 0.008, -.pi / 2 + 0.001, .pi / 2 - 0.001)
        orthographic = false
    }

    public mutating func pan(dx: CGFloat, dy: CGFloat, viewHeight: CGFloat) {
        let s = worldPerPoint(viewHeight: viewHeight)
        target += right * (-Float(dx) * s) + up * (Float(dy) * s)
    }

    public mutating func zoom(factor: Float) {
        distance = clamp(distance * factor, 8, 20000)
    }

    public static func preset(_ v: ViewPreset, framing bounds: AABB?) -> OrbitCamera {
        var c = OrbitCamera()
        (c.yaw, c.pitch) = v.angles
        if v == .top { c.pitch = .pi / 2 - 0.0005 }
        if v == .bottom { c.pitch = -.pi / 2 + 0.0005 }
        c.orthographic = v.isOrthographic
        if let b = bounds, !b.isEmpty {
            c.target = b.center
            c.distance = max(b.radius, 20) * 4.0
        }
        return c
    }

    /// Same angle, re-centred and re-distanced to fit `bounds`.
    public func framing(_ bounds: AABB) -> OrbitCamera {
        var c = self
        guard !bounds.isEmpty else { return c }
        c.target = bounds.center
        c.distance = max(bounds.radius, 20) * 4.0
        return c
    }
}

/// Critically-damped glide between camera poses (used for view presets and mode transitions).
public struct CameraAnimator: Sendable {
    public var goal: OrbitCamera?
    public init() {}

    public var isAnimating: Bool { goal != nil }

    /// Advances `camera` toward the goal. Returns true while still moving.
    public mutating func step(_ camera: inout OrbitCamera, dt: Float) -> Bool {
        guard let g = goal else { return false }
        let k = 1 - exp(-dt * 9)
        camera.yaw += angleDelta(camera.yaw, g.yaw) * k
        camera.pitch += (g.pitch - camera.pitch) * k
        camera.target += (g.target - camera.target) * k
        camera.distance = exp(log(camera.distance) + (log(g.distance) - log(camera.distance)) * k)
        camera.fovY = g.fovY
        let done = abs(angleDelta(camera.yaw, g.yaw)) < 0.002 && abs(g.pitch - camera.pitch) < 0.002
            && simd_distance(camera.target, g.target) < 0.05 && abs(camera.distance - g.distance) < 0.1
        // Orthographic switches on near the end of the glide (Blender's auto-perspective feel).
        if g.orthographic {
            if abs(angleDelta(camera.yaw, g.yaw)) < 0.05 && abs(g.pitch - camera.pitch) < 0.05 { camera.orthographic = true }
        } else {
            camera.orthographic = false
        }
        if done { camera = g; goal = nil }
        return !done
    }
}
