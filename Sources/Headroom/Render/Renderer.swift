import Foundation
import ImageIO
import Metal
import simd

struct SegmentGPU {
    var from: SIMD4<Float>
    var to: SIMD4<Float>
    var colorFrom: SIMD4<Float>
    var colorTo: SIMD4<Float>
    var params: SIMD4<Float>
}

struct UniformsGPU {
    var viewport: SIMD2<Float> = .zero
    var center: SIMD2<Float> = .zero
    var radius: Float = 0
    var t: Float = 1
    var scale: Float = 2
    var dim: Float = 0
    var liftPixels: Float = 0
    var bloom: Float = 1
    var headroom: Float = 1
    var ghost: Float = 0            // share of the disk a cleanup would free
    var freeStart: Float = 0        // where the free wedge begins
    var hideScale: Float = 0
}

/// Draws the ring. Pieces are one instanced quad each, shaped in the fragment shader, so the cost barely depends on
/// how many there are, and a transition only updates one number per frame.
final class MapRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let segmentPipeline: MTLRenderPipelineState
    private let downPipeline: MTLRenderPipelineState
    private let upPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState

    static let hdrFormat: MTLPixelFormat = .rgba16Float
    static let outputFormat: MTLPixelFormat = .rgba16Float

    private var instanceBuffer: MTLBuffer
    private var emphasisBuffer: MTLBuffer
    private(set) var instanceCount = 0
    private var capacity = 16384
    private var emphasisSlot = 0
    private var emphasisOffset = 0

    private var piecesTexture: MTLTexture?
    private var levels: [MTLTexture] = []
    private var renderSize: (Int, Int) = (0, 0)

    init?(device: MTLDevice? = nil, shaders url: URL? = nil) {
        guard let device = device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        queue.label = "ring"
        let sourceURL = url ?? Bundle.main.url(forResource: "Shaders", withExtension: "metal")
        guard let sourceURL, let source = try? String(contentsOf: sourceURL, encoding: .utf8) else { return nil }
        let options = MTLCompileOptions()
        options.mathMode = .fast
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: options)
        } catch {
            print("shaders didn't compile: \(error)")
            return nil
        }

        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat, blended: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            let a = d.colorAttachments[0]!
            a.pixelFormat = format
            if blended {
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let seg = pipeline("segment_vertex", "segment_fragment", format: Self.hdrFormat, blended: true),
              let down = pipeline("quad_vertex", "blur_down", format: Self.hdrFormat, blended: false),
              let up = pipeline("quad_vertex", "blur_up", format: Self.hdrFormat, blended: false),
              let comp = pipeline("quad_vertex", "composite", format: Self.outputFormat, blended: false),
              let instances = device.makeBuffer(length: capacity * MemoryLayout<SegmentGPU>.stride, options: .storageModeShared),
              let emphasis = device.makeBuffer(length: capacity * MemoryLayout<Float>.stride, options: .storageModeShared)
        else { return nil }
        segmentPipeline = seg
        downPipeline = down
        upPipeline = up
        compositePipeline = comp
        instanceBuffer = instances
        emphasisBuffer = emphasis
    }

    /// Hands over this transition's pieces. Frames still being drawn keep the old buffer until they finish.
    func setInstances(_ instances: [SegmentGPU]) {
        instanceCount = instances.count
        guard !instances.isEmpty else { return }
        instances.withUnsafeBytes { raw in
            if let buffer = device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared) {
                instanceBuffer = buffer
            }
        }
        let needed = instances.count * 3 * MemoryLayout<Float>.stride
        if emphasisBuffer.length < needed {
            emphasisBuffer = device.makeBuffer(length: needed * 2, options: .storageModeShared)!
        }
    }

    func writeEmphasis(_ values: [Float]) {
        guard !values.isEmpty else { return }
        let bytes = values.count * MemoryLayout<Float>.stride
        emphasisSlot = (emphasisSlot + 1) % 3
        emphasisOffset = emphasisSlot * bytes
        guard emphasisOffset + bytes <= emphasisBuffer.length else { return }
        values.withUnsafeBytes { raw in
            (emphasisBuffer.contents() + emphasisOffset).copyMemory(from: raw.baseAddress!, byteCount: bytes)
        }
    }

    private func prepareTargets(width: Int, height: Int) {
        if renderSize == (width, height), piecesTexture != nil { return }
        renderSize = (width, height)
        func texture(_ w: Int, _ h: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.hdrFormat, width: max(w, 1), height: max(h, 1), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        piecesTexture = texture(width, height)
        levels = (1...6).map { texture(width >> $0, height >> $0) }
    }

    private func pass(_ commands: MTLCommandBuffer, target: MTLTexture, clear: Bool = false, _ body: (MTLRenderCommandEncoder) -> Void) {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = target
        d.colorAttachments[0].loadAction = clear ? .clear : .dontCare
        d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        d.colorAttachments[0].storeAction = .store
        guard let e = commands.makeRenderCommandEncoder(descriptor: d) else { return }
        body(e)
        e.endEncoding()
    }

    func encode(into commands: MTLCommandBuffer, target: MTLTexture, uniforms: UniformsGPU) {
        let width = target.width, height = target.height
        prepareTargets(width: width, height: height)
        guard let pieces = piecesTexture else { return }
        var u = uniforms

        pass(commands, target: pieces, clear: true) { e in
            e.setRenderPipelineState(segmentPipeline)
            e.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
            e.setVertexBytes(&u, length: MemoryLayout<UniformsGPU>.stride, index: 1)
            e.setVertexBuffer(emphasisBuffer, offset: emphasisOffset, index: 2)
            e.setFragmentBytes(&u, length: MemoryLayout<UniformsGPU>.stride, index: 1)
            if instanceCount > 0 {
                e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instanceCount)
            }
        }

        // Down through a chain of smaller and smaller copies, then back up: a wide glow from few samples.
        var source = pieces
        for level in levels {
            var texel = SIMD2<Float>(1 / Float(source.width), 1 / Float(source.height))
            pass(commands, target: level) { e in
                e.setRenderPipelineState(downPipeline)
                e.setFragmentTexture(source, index: 0)
                e.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            source = level
        }
        var i = levels.count - 2
        while i >= 1 {
            var texel = SIMD2<Float>(0.5 / Float(source.width), 0.5 / Float(source.height))
            let from = source
            pass(commands, target: levels[i]) { e in
                e.setRenderPipelineState(upPipeline)
                e.setFragmentTexture(from, index: 0)
                e.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            source = levels[i]
            i -= 1
        }

        pass(commands, target: target) { e in
            e.setRenderPipelineState(compositePipeline)
            e.setFragmentTexture(pieces, index: 0)
            e.setFragmentTexture(levels[1], index: 1)
            e.setFragmentTexture(levels[levels.count - 2], index: 2)
            e.setFragmentBytes(&u, length: MemoryLayout<UniformsGPU>.stride, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    var commandQueue: MTLCommandQueue { queue }

    /// Renders one frame off screen, for tests and for the app icon.
    func renderPNG(to path: String, width: Int, height: Int, uniforms: UniformsGPU) {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.outputFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .managed
        guard let target = device.makeTexture(descriptor: d), let commands = queue.makeCommandBuffer() else { return }
        encode(into: commands, target: target, uniforms: uniforms)
        if let blit = commands.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        commands.commit()
        commands.waitUntilCompleted()
        Self.writePNG(target, path: path)
    }

    static func writePNG(_ texture: MTLTexture, path: String) {
        let w = texture.width, h = texture.height
        var half = [Float16](repeating: 0, count: w * h * 4)
        texture.getBytes(&half, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 {
                let v = max(0, min(1, Float(half[i * 4 + c])))
                let e = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
                bytes[i * 4 + c] = UInt8(e * 255 + 0.5)
            }
        }
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(out, image, nil)
        CGImageDestinationFinalize(out)
    }
}
