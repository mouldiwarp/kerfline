// The toolpath in Metal, as 1.0's viz/scene.ts: Z up, mm, everything in work coordinates (the
// machine travel box is shifted by the work offset). Lines for the program (to cut, cut, rapids),
// a grid on Z0, the travel box, work-zero axes and a cone for the tool. Draws only when something
// changed. Cut colouring rewrites just the colours that changed, in place.

import AppKit
import SGCore
import Metal
import MetalKit
import simd

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms { float4x4 mvp; float2 viewport; float width; };
struct VOut { float4 position [[position]]; float4 color; };

vertex VOut vmain(uint vid [[vertex_id]],
                  const device packed_float3 *pos [[buffer(0)]],
                  const device float4 *col [[buffer(1)]],
                  constant Uniforms &u [[buffer(2)]]) {
    VOut o;
    o.position = u.mvp * float4(float3(pos[vid]), 1.0);
    o.color = col[vid];
    return o;
}

// Lines as screen-space quads, `width` pixels wide: 6 vertices per segment, one colour per segment.
constant float2 corners[6] = { float2(0, -1), float2(1, -1), float2(1, 1), float2(0, -1), float2(1, 1), float2(0, 1) };

vertex VOut lmain(uint vid [[vertex_id]],
                  const device packed_float3 *pos [[buffer(0)]],
                  const device float4 *col [[buffer(1)]],
                  constant Uniforms &u [[buffer(2)]]) {
    uint seg = vid / 6;
    float2 c = corners[vid % 6];
    float4 a = u.mvp * float4(float3(pos[seg * 2]), 1.0);
    float4 b = u.mvp * float4(float3(pos[seg * 2 + 1]), 1.0);
    // Clip against the near plane so the ends stay in front of the camera.
    const float n = 1e-4;
    if (a.w < n && b.w >= n) a = mix(a, b, (n - a.w) / (b.w - a.w));
    if (b.w < n && a.w >= n) b = mix(b, a, (n - b.w) / (a.w - b.w));
    float2 sa = a.xy / a.w * u.viewport * 0.5;
    float2 sb = b.xy / b.w * u.viewport * 0.5;
    float2 d = sb - sa;
    float len = length(d);
    float2 dir = len > 1e-5 ? d / len : float2(1, 0);
    float2 normal = float2(-dir.y, dir.x);
    float4 p = c.x > 0.5 ? b : a;
    float2 off = (normal * c.y + dir * (c.x > 0.5 ? 0.5 : -0.5)) * u.width * 0.5;
    p.xy += off / (u.viewport * 0.5) * p.w;
    VOut o;
    o.position = (a.w < n && b.w < n) ? float4(0, 0, -2, 1) : p;
    o.color = col[seg];
    return o;
}

fragment float4 fmain(VOut in [[stage_in]]) { return in.color; }
"""

enum VizColor {
    static let feed = SIMD4<Float>(0x9a, 0x9a, 0x9a, 255) / 255
    static let rapid = SIMD4<Float>(0x4a, 0x4a, 0x4a, 255) / 255
    static let feedDone = SIMD4<Float>(0xc5, 0xa0, 0x59, 255) / 255
    static let rapidDone = SIMD4<Float>(0x6b, 0x5a, 0x35, 255) / 255
    static let grid = SIMD4<Float>(0x24, 0x24, 0x24, 255) / 255
    static let gridMajor = SIMD4<Float>(0x30, 0x30, 0x30, 255) / 255
    static let envelope = SIMD4<Float>(0x5a, 0x5a, 0x5a, 255) / 255
    static let tool = SIMD4<Float>(0xd8, 0xb6, 0x72, 255) / 255
    static let x = SIMD4<Float>(0xd9, 0x6b, 0x6b, 255) / 255
    static let y = SIMD4<Float>(0x7f, 0xbf, 0x6a, 255) / 255
    static let z = SIMD4<Float>(0x6a, 0x9f, 0xd9, 255) / 255
}

/// GPU buffers for one draw. Lines: two points and one colour per segment. Triangles: a point and
/// a colour per vertex.
private struct Mesh {
    var positions: MTLBuffer
    var colors: MTLBuffer
    /// Segments (lines) or vertices (triangles).
    var count: Int
    var lines: Bool
    var width: Float

    @MainActor init?(_ device: MTLDevice, _ pos: [SIMD3<Float>], _ col: [SIMD4<Float>], lines: Bool, width: Float = 1) {
        guard !pos.isEmpty else { return nil }
        // packed_float3 on the GPU: 12 bytes per point.
        var flat = [Float]()
        flat.reserveCapacity(pos.count * 3)
        for p in pos { flat += [p.x, p.y, p.z] }
        guard let pb = device.makeBuffer(bytes: flat, length: flat.count * 4, options: .storageModeShared),
            let cb = device.makeBuffer(bytes: col, length: col.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)
        else { return nil }
        positions = pb
        colors = cb
        count = lines ? pos.count / 2 : pos.count
        self.lines = lines
        self.width = width
    }
}

private struct Uniforms {
    var mvp: simd_float4x4
    var viewport: SIMD2<Float>
    var width: Float
}

@MainActor
final class ToolpathRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let linePipeline: MTLRenderPipelineState
    private let triPipeline: MTLRenderPipelineState
    private let depth: MTLDepthStencilState
    private let background: MTLDepthStencilState
    weak var view: MTKView?

    var camera = OrbitCamera()
    private(set) var viewName: ViewName = .iso

    private var paths: Mesh?
    private var segLines: [Int32] = []
    private var segRapid: [Bool] = []
    private var doneCount = 0
    private var grid: [Mesh] = []
    private var envelope: Mesh?
    private var axes: Mesh?
    private var tool: Mesh?
    private var toolAt: SIMD3<Float>?
    private var toolScale: Float = 1.2
    private var axesScale: Float = 1
    private var bounds: Bounds?

    /// What a view fits: the program plus work zero and its axes, so the gizmo stays on screen.
    private var fitBounds: Bounds? {
        guard let b = bounds else { return nil }
        let a = Double(20 * axesScale)
        return Bounds(min: Vec3(Swift.min(b.min.x, 0), Swift.min(b.min.y, 0), Swift.min(b.min.z, 0)),
            max: Vec3(Swift.max(b.max.x, a), Swift.max(b.max.y, a), Swift.max(b.max.z, a)))
    }

    init?(device: MTLDevice, sampleCount: Int) {
        guard let queue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: shaderSource, options: nil)
        else { return nil }
        func pipeline(_ vertex: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: "fmain")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.depthAttachmentPixelFormat = .depth32Float
            d.rasterSampleCount = sampleCount
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let lp = pipeline("lmain"), let tp = pipeline("vmain") else { return nil }
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .lessEqual
        ds.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: ds),
            let background = device.makeDepthStencilState(descriptor: MTLDepthStencilDescriptor())
        else { return nil }
        self.device = device
        self.queue = queue
        linePipeline = lp
        triPipeline = tp
        self.depth = depth
        self.background = background
        super.init()
        axes = makeAxes()
        tool = makeTool()
        setGrid(nil)
        camera.fit(nil, .iso)
    }

    func redraw() { view?.needsDisplay = true }

    // MARK: Content

    /// Draw `segments` (nil clears it) and fit the view to `bounds`.
    func setProgram(_ segments: [Segment]?, bounds: Bounds?) {
        paths = nil
        doneCount = 0
        self.bounds = bounds
        segLines = []
        segRapid = []
        if let segments, !segments.isEmpty {
            var pos = [SIMD3<Float>]()
            var col = [SIMD4<Float>]()
            pos.reserveCapacity(segments.count * 2)
            col.reserveCapacity(segments.count)
            segLines.reserveCapacity(segments.count)
            segRapid.reserveCapacity(segments.count)
            for s in segments {
                let rapid = s.type == .rapid
                pos.append(SIMD3<Float>(s.from))
                pos.append(SIMD3<Float>(s.to))
                col.append(rapid ? VizColor.rapid : VizColor.feed)
                segLines.append(Int32(clamping: s.line))
                segRapid.append(rapid)
            }
            paths = Mesh(device, pos, col, lines: true, width: 1.6)
        }
        setGrid(bounds)
        let diag: Float = bounds.map { Float(simd_length($0.max - $0.min)) } ?? 100
        toolScale = max(diag / 60, 1.2)
        axesScale = max(diag / 120, 0.5)
        setView(viewName)
    }

    /// Colour every segment from source lines ≤ `line` as cut (-1: none).
    func setProgress(_ line: Int) {
        guard let paths else { return }
        // Segments are in source order: find the first past `line`.
        var lo = 0, hi = segLines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(segLines[mid]) <= line { lo = mid + 1 } else { hi = mid }
        }
        let target = lo
        guard target != doneCount else { return }
        let done = target > doneCount
        let colors = paths.colors.contents().bindMemory(to: SIMD4<Float>.self, capacity: paths.count)
        for i in min(target, doneCount)..<max(target, doneCount) {
            colors[i] = segRapid[i] ? (done ? VizColor.rapidDone : VizColor.rapid) : (done ? VizColor.feedDone : VizColor.feed)
        }
        doneCount = target
        redraw()
    }

    func setTool(_ p: Vec3?) {
        let new = p.map { SIMD3<Float>($0) }
        guard new != toolAt else { return }
        toolAt = new
        redraw()
    }

    func setEnvelope(_ b: Bounds?) {
        envelope = b.flatMap { box($0, VizColor.envelope) }
        redraw()
    }

    func setView(_ v: ViewName) {
        viewName = v
        camera.fit(fitBounds, v)
        redraw()
    }

    // MARK: Geometry

    private func setGrid(_ b: Bounds?) {
        let b = b ?? Bounds(min: .zero, max: Vec3(100, 100, 0))
        let ext = max(b.max.x - b.min.x, b.max.y - b.min.y, 50)
        let step: Double = ext > 1500 ? 100 : ext > 300 ? 50 : 10
        let pad = step * 2
        let x0 = ((min(b.min.x, 0) - pad) / step).rounded(.down) * step
        let x1 = ((max(b.max.x, 0) + pad) / step).rounded(.up) * step
        let y0 = ((min(b.min.y, 0) - pad) / step).rounded(.down) * step
        let y1 = ((max(b.max.y, 0) + pad) / step).rounded(.up) * step
        var minor = [SIMD3<Float>](), major = [SIMD3<Float>]()
        let z: Float = -0.01
        func isMajor(_ v: Double) -> Bool { abs((v / (step * 5)).rounded() * step * 5 - v) < 1e-6 }
        for x in stride(from: x0, through: x1, by: step) {
            let l = [SIMD3<Float>(Float(x), Float(y0), z), SIMD3<Float>(Float(x), Float(y1), z)]
            if isMajor(x) { major += l } else { minor += l }
        }
        for y in stride(from: y0, through: y1, by: step) {
            let l = [SIMD3<Float>(Float(x0), Float(y), z), SIMD3<Float>(Float(x1), Float(y), z)]
            if isMajor(y) { major += l } else { minor += l }
        }
        grid = [
            Mesh(device, minor, Array(repeating: VizColor.grid, count: minor.count / 2), lines: true, width: 1),
            Mesh(device, major, Array(repeating: VizColor.gridMajor, count: major.count / 2), lines: true, width: 1),
        ].compactMap { $0 }
    }

    private func box(_ b: Bounds, _ c: SIMD4<Float>) -> Mesh? {
        let lo = SIMD3<Float>(b.min), hi = SIMD3<Float>(b.max)
        func p(_ i: Int) -> SIMD3<Float> { SIMD3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z) }
        let edges = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        let pos = edges.flatMap { [p($0.0), p($0.1)] }
        return Mesh(device, pos, Array(repeating: c, count: edges.count), lines: true, width: 1.2)
    }

    private func makeAxes() -> Mesh? {
        let pos: [SIMD3<Float>] = [.zero, SIMD3(20, 0, 0), .zero, SIMD3(0, 20, 0), .zero, SIMD3(0, 0, 20)]
        return Mesh(device, pos, [VizColor.x, VizColor.y, VizColor.z], lines: true, width: 2.5)
    }

    /// A cone with its tip at the origin, 4 tall and 1 in radius, pointing down.
    private func makeTool() -> Mesh? {
        let n = 24
        var pos = [SIMD3<Float>]()
        var col = [SIMD4<Float>]()
        for i in 0..<n {
            let a0 = Float(i) / Float(n) * 2 * .pi, a1 = Float(i + 1) / Float(n) * 2 * .pi
            let r0 = SIMD3<Float>(cos(a0), sin(a0), 4), r1 = SIMD3<Float>(cos(a1), sin(a1), 4)
            // Side, shaded by which way it faces so the cone reads as 3D.
            let shade = 0.55 + 0.45 * (0.5 + 0.5 * cos((a0 + a1) / 2 - 2.2))
            pos += [.zero, r0, r1]
            col += Array(repeating: SIMD4(VizColor.tool.x * shade, VizColor.tool.y * shade, VizColor.tool.z * shade, 1), count: 3)
            pos += [SIMD3(0, 0, 4), r1, r0]
            col += Array(repeating: VizColor.tool, count: 3)
        }
        return Mesh(device, pos, col, lines: false)
    }

    // MARK: Drawing

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated {
            let first = camera.aspect == 1
            camera.aspect = Float(max(size.width, 1) / max(size.height, 1))
            if first { camera.fit(fitBounds, viewName) }
            view.needsDisplay = true
        }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(view) }
    }

    private func render(_ view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
            let cmd = queue.makeCommandBuffer()
        else { return }
        let size = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))
        encode(cmd, pass, size: size, scale: Float(view.window?.backingScaleFactor ?? 2))
        cmd.present(drawable)
        cmd.commit()
    }

    private func encode(_ cmd: MTLCommandBuffer, _ pass: MTLRenderPassDescriptor, size: SIMD2<Float>, scale: Float) {
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let vp = camera.projection * camera.view

        func draw(_ m: Mesh?, _ model: simd_float4x4 = matrix_identity_float4x4) {
            guard let m else { return }
            var u = Uniforms(mvp: vp * model, viewport: size, width: m.width * scale)
            enc.setRenderPipelineState(m.lines ? linePipeline : triPipeline)
            enc.setVertexBuffer(m.positions, offset: 0, index: 0)
            enc.setVertexBuffer(m.colors, offset: 0, index: 1)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: m.lines ? m.count * 6 : m.count)
        }

        // The grid is the floor: drawn first, without depth, so nothing fights with it.
        enc.setDepthStencilState(background)
        grid.forEach { draw($0) }
        enc.setDepthStencilState(depth)
        draw(envelope)
        draw(paths)
        draw(axes, scaleMatrix(axesScale))
        if let t = toolAt { draw(tool, translate(t) * scaleMatrix(toolScale)) }
        enc.endEncoding()
    }

    /// Render offscreen (for tests): BGRA bytes, `width` × `height`, rows top first.
    func snapshot(width: Int, height: Int, sampleCount: Int) -> [UInt8]? {
        func texture(_ format: MTLPixelFormat, _ samples: Int, _ usage: MTLTextureUsage) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples
            d.usage = usage
            d.storageMode = samples > 1 || format == .depth32Float ? .private : .shared
            return device.makeTexture(descriptor: d)
        }
        guard let color = texture(.bgra8Unorm, sampleCount, .renderTarget), let resolve = texture(.bgra8Unorm, 1, [.renderTarget, .shaderRead]),
            let depthTex = texture(.depth32Float, sampleCount, .renderTarget), let cmd = queue.makeCommandBuffer()
        else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = sampleCount > 1 ? color : resolve
        if sampleCount > 1 { pass.colorAttachments[0].resolveTexture = resolve }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = sampleCount > 1 ? .multisampleResolve : .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.depthAttachment.texture = depthTex
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        camera.aspect = Float(width) / Float(height)
        camera.fit(fitBounds, viewName)
        encode(cmd, pass, size: SIMD2(Float(width), Float(height)), scale: 1)
        cmd.commit()
        cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        resolve.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }
}

private func scaleMatrix(_ s: Float) -> simd_float4x4 { simd_float4x4(diagonal: SIMD4(s, s, s, 1)) }

private func translate(_ t: SIMD3<Float>) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(t, 1)
    return m
}

/// The MTKView: draws on demand, and turns the mouse and trackpad into camera moves.
final class ToolpathMTKView: MTKView {
    var renderer: ToolpathRenderer?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDragged(with e: NSEvent) {
        guard let r = renderer else { return }
        if e.modifierFlags.contains(.option) || e.modifierFlags.contains(.shift) {
            r.camera.pan(dx: Float(e.deltaX), dy: Float(e.deltaY), height: Float(bounds.height))
        } else {
            r.camera.orbit(dx: Float(e.deltaX), dy: Float(e.deltaY))
        }
        r.redraw()
    }

    override func rightMouseDragged(with e: NSEvent) { pan(e) }
    override func otherMouseDragged(with e: NSEvent) { pan(e) }

    private func pan(_ e: NSEvent) {
        guard let r = renderer else { return }
        r.camera.pan(dx: Float(e.deltaX), dy: Float(e.deltaY), height: Float(bounds.height))
        r.redraw()
    }

    override func scrollWheel(with e: NSEvent) {
        guard let r = renderer else { return }
        let dy = Float(e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 10)
        r.camera.zoom(exp(-dy * 0.005))
        r.redraw()
    }

    override func magnify(with e: NSEvent) {
        guard let r = renderer else { return }
        r.camera.zoom(1 / max(0.2, 1 + Float(e.magnification)))
        r.redraw()
    }

    override func mouseUp(with e: NSEvent) {
        if e.clickCount == 2, let r = renderer { r.setView(r.viewName) }
    }
}
