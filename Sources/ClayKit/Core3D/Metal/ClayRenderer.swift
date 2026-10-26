import Foundation
import Metal
import MetalKit
import CoreGraphics
import simd

/// A polyline drawn in world space (sketch curves, guides, axes).
public struct CurveStroke: Sendable {
    public var points: [Vec3]
    public var color: Vec4
    public var width: Float
    public var closed: Bool
    public init(points: [Vec3], color: Vec4, width: Float, closed: Bool = false) {
        self.points = points; self.color = color; self.width = width; self.closed = closed
    }
}

/// Linear-space colours the renderer needs from the active studio theme.
public struct RenderPalette: Sendable {
    public var clay = Vec4(0.80, 0.62, 0.50, 1)
    public var rim = Vec4(1.0, 0.9, 0.8, 0.35)
    public var sky = Vec4(0.92, 0.92, 0.96, 1)
    public var ground = Vec4(0.42, 0.36, 0.32, 1)
    public var bgTop = Vec4(0.86, 0.84, 0.82, 1)
    public var bgBottom = Vec4(0.66, 0.64, 0.62, 1)
    public var grid = Vec4(0.25, 0.22, 0.2, 0.35)
    public var axisX = Vec4(0.85, 0.25, 0.22, 1)
    public var axisZ = Vec4(0.2, 0.42, 0.9, 1)
    public var wire = Vec4(0.1, 0.08, 0.07, 0.22)
    public var brush = Vec4(1, 1, 1, 0.85)
    public init() {}
}

/// Everything the viewport draws in one frame.
public struct RenderScene: Sendable {
    public var mesh: ClayMesh?
    public var modelMatrix: Mat4 = .identity
    public var camera = OrbitCamera()
    public var palette = RenderPalette()
    public var showWireframe = false
    public var showGrid = true
    /// 0…1 loft "growing" animation (nil = fully shown).
    public var reveal: Float?
    public var brush: (center: Vec3, radius: Float)?
    public var curves: [CurveStroke] = []
    public var overlayCurves: [CurveStroke] = []
    public var time: Float = 0
    public init() {}
}

/// Compiled shaders and fixed GPU state, built once per process (compiling the shader source
/// takes a moment) and shared by every renderer.
public final class RenderPipelines {
    public let device: MTLDevice
    let queue: MTLCommandQueue
    let bg, clay, wire, line, grid: MTLRenderPipelineState
    let depthWrite, depthRead, depthNone: MTLDepthStencilState

    private static var cached: RenderPipelines?
    public static func shared() -> RenderPipelines? {
        if let c = cached { return c }
        guard let d = MTLCreateSystemDefaultDevice(), let p = try? RenderPipelines(device: d) else { return nil }
        cached = p
        return p
    }

    init(device: MTLDevice) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw NSError(domain: "Clay", code: 1) }
        queue = q
        let lib = try device.makeLibrary(source: ClayShaders.source, options: nil)

        func pipeline(_ v: String, _ f: String, blend: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = ClayRenderer.colorFormat
            d.depthAttachmentPixelFormat = ClayRenderer.depthFormat
            d.rasterSampleCount = ClayRenderer.sampleCount
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        bg = try pipeline("bg_vertex", "bg_fragment", blend: false)
        clay = try pipeline("clay_vertex", "clay_fragment", blend: false)
        wire = try pipeline("wire_vertex", "wire_fragment", blend: true)
        line = try pipeline("thick_vertex", "thick_fragment", blend: true)
        grid = try pipeline("grid_vertex", "grid_fragment", blend: true)

        func depth(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        depthWrite = depth(.lessEqual, write: true)
        depthRead = depth(.lessEqual, write: false)
        depthNone = depth(.always, write: false)
    }
}

/// Metal viewport renderer: studio background, clay surface, wireframe, ground grid with a
/// contact shadow, and thick anti-aliased curves. Works on screen (MTKView) and off screen.
/// Each viewport owns one (it caches that viewport's GPU mesh buffers).
public final class ClayRenderer: NSObject {
    public static let colorFormat: MTLPixelFormat = .bgra8Unorm_srgb
    public static let depthFormat: MTLPixelFormat = .depth32Float
    public static let sampleCount = 4

    let gpu: RenderPipelines
    public var device: MTLDevice { gpu.device }
    var queue: MTLCommandQueue { gpu.queue }

    // Mesh GPU cache
    private var meshRevision: UInt64 = 0
    private var topoRevision: UInt64 = 0
    private var positionBuffer, normalBuffer, indexBuffer, edgeBuffer: MTLBuffer?
    private var indexCount = 0, edgeCount = 0

    /// Called every frame before drawing (on screen) to fetch the current scene.
    public var sceneProvider: (() -> RenderScene)?
    public var onFrame: ((Float) -> Void)?
    private var lastFrame = CACurrentMediaTime()

    public init?(pipelines: RenderPipelines? = RenderPipelines.shared()) {
        guard let pipelines else { return nil }
        gpu = pipelines
        super.init()
    }

    // MARK: Uniforms (must match `Uniforms` in Shaders.swift)

    struct Uniforms {
        var viewProj: Mat4
        var model: Mat4
        var cameraPos, viewDir, albedo, rim, keyLight, fillLight, skyColor, groundColor: Vec4
        var reveal, brush, brushColor, viewport, lineColor, shadow, grid, gridColor, axisX, axisZ, bgTop, bgBottom: Vec4
    }

    struct Segment { var a: Vec4; var b: Vec4; var color: Vec4 }

    private func uniforms(_ s: RenderScene, drawable: CGSize) -> Uniforms {
        let aspect = Float(drawable.width / max(drawable.height, 1))
        let cam = s.camera
        let p = s.palette
        let b = s.mesh?.bounds ?? AABB(min: Vec3(-30, 0, -30), max: Vec3(30, 60, 30))
        let ground = min(b.min.y, 0)
        var reveal = Vec4.zero
        if let r = s.reveal, !b.isEmpty {
            reveal = Vec4(b.min.y + (b.max.y - b.min.y) * r, max(b.size.y * 0.05, 1), 1, s.time)
        }
        let brush = s.brush.map { Vec4($0.center.x, $0.center.y, $0.center.z, $0.radius) } ?? .zero
        // Lights follow the camera a little so the form always reads well.
        let key = (cam.right * -0.55 + cam.up * 0.75 - cam.forward * 0.6).safeNormalized
        let fill = (cam.right * 0.8 + cam.up * 0.15 - cam.forward * 0.4).safeNormalized
        let gridExtent = max(cam.distance * 3, 600)
        let shadowR = max(b.size.x, b.size.z) * 0.75 + 4
        return Uniforms(
            viewProj: cam.viewProjection(aspect: aspect),
            model: s.modelMatrix,
            cameraPos: Vec4(cam.eye.x, cam.eye.y, cam.eye.z, cam.orthographic ? 1 : 0),
            viewDir: Vec4(cam.forward.x, cam.forward.y, cam.forward.z, 0),
            albedo: p.clay, rim: p.rim,
            keyLight: Vec4(key.x, key.y, key.z, 0.95),
            fillLight: Vec4(fill.x, fill.y, fill.z, 0.32),
            skyColor: p.sky, groundColor: p.ground,
            reveal: reveal, brush: brush, brushColor: p.brush,
            viewport: Vec4(Float(drawable.width), Float(drawable.height), 0, 0),
            lineColor: p.wire,
            shadow: Vec4(b.center.x, ground, b.center.z, (s.mesh?.isEmpty ?? true) ? 0.001 : shadowR),
            grid: Vec4(10, 50, gridExtent, ground),
            gridColor: p.grid, axisX: p.axisX, axisZ: p.axisZ,
            bgTop: p.bgTop, bgBottom: p.bgBottom)
    }

    private func updateMeshBuffers(_ mesh: ClayMesh?) {
        guard let mesh, !mesh.isEmpty else {
            positionBuffer = nil; normalBuffer = nil; indexBuffer = nil; edgeBuffer = nil
            indexCount = 0; edgeCount = 0; meshRevision = 0; topoRevision = 0
            return
        }
        if mesh.revision != meshRevision {
            // Fresh buffers each update: no CPU/GPU race on buffers still in flight.
            positionBuffer = mesh.positions.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            normalBuffer = mesh.normals.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            meshRevision = mesh.revision
        }
        if mesh.topologyRevision != topoRevision {
            indexBuffer = mesh.indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            indexCount = mesh.indices.count
            let edges = mesh.edgeIndices()
            edgeBuffer = edges.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 4), options: .storageModeShared) }
            edgeCount = edges.count
            topoRevision = mesh.topologyRevision
        }
    }

    private func segments(_ curves: [CurveStroke]) -> [Segment] {
        var out: [Segment] = []
        for c in curves where c.points.count >= 2 {
            let n = c.points.count
            let count = c.closed ? n : n - 1
            for i in 0..<count {
                let a = c.points[i], b = c.points[(i + 1) % n]
                out.append(Segment(a: Vec4(a.x, a.y, a.z, c.width), b: Vec4(b.x, b.y, b.z, 0), color: c.color))
            }
        }
        return out
    }

    // MARK: Encoding

    func encode(_ s: RenderScene, encoder enc: MTLRenderCommandEncoder, drawableSize: CGSize) {
        var u = uniforms(s, drawable: drawableSize)
        let ulen = MemoryLayout<Uniforms>.stride
        updateMeshBuffers(s.mesh)

        enc.setFrontFacing(.counterClockwise)
        enc.setCullMode(.none)

        // Background
        enc.setRenderPipelineState(gpu.bg)
        enc.setDepthStencilState(gpu.depthNone)
        enc.setFragmentBytes(&u, length: ulen, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Clay
        if let pb = positionBuffer, let nb = normalBuffer, let ib = indexBuffer, indexCount > 0 {
            enc.setRenderPipelineState(gpu.clay)
            enc.setDepthStencilState(gpu.depthWrite)
            enc.setVertexBuffer(pb, offset: 0, index: 0)
            enc.setVertexBuffer(nb, offset: 0, index: 1)
            enc.setVertexBytes(&u, length: ulen, index: 2)
            enc.setFragmentBytes(&u, length: ulen, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)

            if s.showWireframe, let eb = edgeBuffer, edgeCount > 0, s.reveal == nil {
                enc.setRenderPipelineState(gpu.wire)
                enc.setDepthStencilState(gpu.depthRead)
                enc.setDepthBias(-2, slopeScale: -2, clamp: 0)
                enc.setVertexBuffer(pb, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: ulen, index: 2)
                enc.setFragmentBytes(&u, length: ulen, index: 0)
                enc.drawIndexedPrimitives(type: .line, indexCount: edgeCount, indexType: .uint32, indexBuffer: eb, indexBufferOffset: 0)
                enc.setDepthBias(0, slopeScale: 0, clamp: 0)
            }
        }

        // Ground grid + shadow (depth-tested so the body hides it)
        if s.showGrid {
            enc.setRenderPipelineState(gpu.grid)
            enc.setDepthStencilState(gpu.depthRead)
            enc.setVertexBytes(&u, length: ulen, index: 2)
            enc.setFragmentBytes(&u, length: ulen, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // Curves: depth-tested ones, then overlay ones on top.
        for (curves, state) in [(s.curves, gpu.depthRead), (s.overlayCurves, gpu.depthNone)] {
            let segs = segments(curves)
            guard !segs.isEmpty else { continue }
            let len = segs.count * MemoryLayout<Segment>.stride
            guard let buf = segs.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: len, options: .storageModeShared) }) else { continue }
            enc.setRenderPipelineState(gpu.line)
            enc.setDepthStencilState(state)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: ulen, index: 2)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: segs.count)
        }
    }

    // MARK: Offscreen (thumbnails, snapshots)

    /// Renders the scene to an sRGB image without any window.
    public func renderImage(_ scene: RenderScene, width: Int, height: Int) -> CGImage? {
        func tex(_ fmt: MTLPixelFormat, samples: Int, usage: MTLTextureUsage, storage: MTLStorageMode) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: width, height: height, mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples
            d.usage = usage
            d.storageMode = storage
            return device.makeTexture(descriptor: d)
        }
        #if os(macOS)
        let readable: MTLStorageMode = .managed
        #else
        let readable: MTLStorageMode = .shared
        #endif
        guard let msaa = tex(Self.colorFormat, samples: Self.sampleCount, usage: .renderTarget, storage: .private),
              let resolve = tex(Self.colorFormat, samples: 1, usage: [.renderTarget, .shaderRead], storage: readable),
              let depth = tex(Self.depthFormat, samples: Self.sampleCount, usage: .renderTarget, storage: .private),
              let cb = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = resolve
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(scene, encoder: enc, drawableSize: CGSize(width: width, height: height))
        enc.endEncoding()
        #if os(macOS)
        if let blit = cb.makeBlitCommandEncoder() { blit.synchronize(resource: resolve); blit.endEncoding() }
        #endif
        cb.commit()
        cb.waitUntilCompleted()

        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        resolve.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - MTKView delegate

extension ClayRenderer: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastFrame, 0.1))
        lastFrame = now
        onFrame?(dt)
        guard let scene = sceneProvider?(),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        encode(scene, encoder: enc, drawableSize: view.drawableSize)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}
