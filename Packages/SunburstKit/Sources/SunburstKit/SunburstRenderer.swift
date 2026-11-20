import Foundation
import ImageIO
import Metal
import os
import simd

struct SegmentGPU {
    var from: SIMD4<Float>
    var to: SIMD4<Float>
    var colorFrom: SIMD4<Float>
    var colorTo: SIMD4<Float>
    var params: SIMD4<Float>
    var plan: SIMD4<Float> = .zero      // marked at the start of the transition, marked at the end
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
    var hideScale: Float = 0        // 1 leaves out the scale around the ring
    var restSaturation: Float = 1
    var glowAtRest: Float = 1
    var minLit: Float = 0           // points: the least a lit piece is drawn across while a tint shows
    var layer: Float = 0            // which pieces this pass draws: 0 the ones at rest, 1 the lit, 2 the lifted, 3 the one on top
    var litAbove: Float = 1         // how lit a piece has to be to count as lit, for that
    var top: Float = -1             // the piece pointed at, which lies over all the others; -1 when there's none
    var tint: SIMD4<Float> = .zero  // the colour lit pieces take on, and in w how much
}

/// Draws the ring. Pieces are one instanced quad each, shaped in the fragment shader, so the cost barely depends on
/// how many there are, and a transition only updates one number per frame.
@_spi(Diagnostics) public final class SunburstRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let segmentPipeline: MTLRenderPipelineState
    private let downPipeline: MTLRenderPipelineState
    private let upPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let narrowCompositePipeline: MTLRenderPipelineState?

    static let hdrFormat: MTLPixelFormat = .rgba16Float
    /// The picture on screen, when the screen can show more than white: the glow goes up to whatever the screen allows.
    public static let outputFormat: MTLPixelFormat = .rgba16Float
    /// The same picture in half the memory, for a screen that can go little or not at all past white. The ring never draws
    /// brighter than the screen can show, and 10 bits a colour, curved like the eye sees, hold every value up to about 1.6
    /// times white.
    public static let narrowOutputFormat: MTLPixelFormat = .bgr10_xr_srgb

    /// Which of the two the screen needs now. Up to 1.5 times white, the narrow one holds it all, with room to spare. Only
    /// Apple's own chips can draw the narrow one, so on any other Mac it's always the first.
    func screenFormat(headroom: CGFloat) -> MTLPixelFormat {
        headroom > 1.5 || narrowCompositePipeline == nil ? Self.outputFormat : Self.narrowOutputFormat
    }

    private var instanceBuffer: MTLBuffer
    private var emphasisBuffer: MTLBuffer
    private(set) var instanceCount = 0
    private var emphasisSlot = 0
    private var emphasisOffset = 0
    /// Pieces that stand out past their place: the one you're pointing at, and one still settling back after it. They're

    private var piecesTexture: MTLTexture?
    private var glowTexture: MTLTexture?
    private var levels: [MTLTexture] = []
    private var renderSize: (Int, Int) = (0, 0)
    private var isResting = false

    /// The shaders are built in: their source, `Shaders.metal`, is compiled when the first renderer is made. `shaders` is a
    /// file of that source to use instead, for working on them.
    init?(device: MTLDevice? = nil, shaders url: URL? = nil) {
        guard let device = device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        queue.label = "ring"
        let given = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        if url != nil, given == nil { return nil }
        guard let library = Self.library(source: given ?? ShaderSource.metal, device: device) else { return nil }

        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat, blended: Bool, targets: Int = 1) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            for target in 0..<targets {
                let a = d.colorAttachments[target]!
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
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let seg = pipeline("segment_vertex", "segment_fragment", format: Self.hdrFormat, blended: true, targets: 2),
              let down = pipeline("quad_vertex", "blur_down", format: Self.hdrFormat, blended: false),
              let up = pipeline("quad_vertex", "blur_up", format: Self.hdrFormat, blended: false),
              let comp = pipeline("quad_vertex", "composite", format: Self.outputFormat, blended: false),
              // Both are replaced by ones of the right size as soon as there's something to draw.
              let instances = device.makeBuffer(length: MemoryLayout<SegmentGPU>.stride, options: .storageModeShared),
              let emphasis = device.makeBuffer(length: 3 * MemoryLayout<Float>.stride, options: .storageModeShared)
        else { return nil }
        segmentPipeline = seg
        downPipeline = down
        upPipeline = up
        compositePipeline = comp
        narrowCompositePipeline = pipeline("quad_vertex", "composite", format: Self.narrowOutputFormat, blended: false)
        instanceBuffer = instances
        emphasisBuffer = emphasis
    }

    /// The shaders compiled for a GPU. The built-in ones are compiled once per GPU and shared, so every chart after the first
    /// starts at once.
    private static func library(source: String, device: MTLDevice) -> MTLLibrary? {
        let key = "\(device.registryID) \(source.hashValue)"
        if let known = compiled.withLock({ $0[key] }) { return known }
        let options = MTLCompileOptions()
        if #available(macOS 15.0, *) { options.mathMode = .fast } else { options.fastMathEnabled = true }
        do {
            let library = try device.makeLibrary(source: source, options: options)
            compiled.withLock { $0[key] = library }
            return library
        } catch {
            print("SunburstKit: the shaders didn't compile: \(error)")
            return nil
        }
    }

    private static let compiled = OSAllocatedUnfairLock(initialState: [String: MTLLibrary]())

    /// Hands over this transition's pieces. Frames still being drawn keep the old buffer until they finish.
    func setInstances(_ instances: [SegmentGPU]) {
        guard !instances.isEmpty else {
            instanceCount = 0
            return
        }
        // Short of memory, the buffers already here stay, and so does the number of pieces they're drawn with: a number
        // larger than a buffer holds would have the GPU read past its end.
        let needed = instances.count * 3 * MemoryLayout<Float>.stride
        if emphasisBuffer.length < needed {
            guard let bigger = device.makeBuffer(length: needed * 2, options: .storageModeShared) else { return }
            emphasisBuffer = bigger
        }
        let made = instances.withUnsafeBytes { raw in device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared) }
        guard let made else { return }
        instanceBuffer = made
        instanceCount = instances.count
    }

    /// How lit each piece is now, and which one is pointed at, if any.
    func writeEmphasis(_ values: [Float], top: Int? = nil) {
        self.top = top
        guard !values.isEmpty else { return }
        let bytes = values.count * MemoryLayout<Float>.stride
        // The buffer is three places of the same size, used in turn, so the frames the GPU is still drawing keep reading
        // theirs whole, also when the number of pieces has just changed.
        let place = emphasisBuffer.length / 3 / MemoryLayout<Float>.stride * MemoryLayout<Float>.stride
        // A buffer that couldn't grow keeps the emphasis it last held, rather than one the GPU would read past its end.
        guard bytes <= place else { return }
        emphasisSlot = (emphasisSlot + 1) % 3
        emphasisOffset = emphasisSlot * place
        values.withUnsafeBytes { raw in
            (emphasisBuffer.contents() + emphasisOffset).copyMemory(from: raw.baseAddress!, byteCount: bytes)
        }
        mostLit = values.max() ?? 0
    }

    /// How lit the most lit piece is, as last written: whether there's anything for the passes after the first to draw.
    private var mostLit: Float = 0
    /// The piece pointed at. It's drawn last, however lit it is yet: a piece the pointer just left is still as lit, or
    /// more, for a moment, and would lie over this one growing into its place.
    private var top: Int?
    /// How lit a piece has to be to be drawn over its neighbours while a tint shows.
    private static let litAbove: Float = 0.9

    /// Whether lit pieces are drawn over the others: while a tint shows.
    var liftLit = false

    private func prepareTargets(width: Int, height: Int) {
        if renderSize == (width, height), piecesTexture != nil { return }
        func texture(_ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.hdrFormat, width: max(w, 1), height: max(h, 1), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        // Short of memory, one may not be made. Then this frame of the ring stays empty, and the next one asks again.
        let made = [texture(width, height), texture(width, height)] + (1...6).map { texture(width >> $0, height >> $0) }
        guard made.allSatisfy({ $0 != nil }) else {
            piecesTexture = nil
            return
        }
        renderSize = (width, height)
        piecesTexture = made[0]
        glowTexture = made[1]
        levels = made.dropFirst(2).compactMap { $0 }
    }

    /// The ring only redraws while something moves, and every frame starts these from nothing. So while it's still, the
    /// system may have their memory back. Call this only once the last frame has finished drawing.
    func rest() {
        guard !isResting else { return }
        isResting = true
        for texture in [piecesTexture, glowTexture].compactMap({ $0 }) + levels { texture.setPurgeableState(.volatile) }
    }

    /// For a check: what each texture takes, and what the GPU holds for this app in all.
    func allocations() -> String {
        let named = [("pieces", piecesTexture), ("glow", glowTexture)] + levels.enumerated().map { ("level \($0.offset + 1)", $0.element as MTLTexture?) }
        let each = named.compactMap { name, texture in
            texture.map { "\(name) \($0.width)x\($0.height) \(String(format: "%.1f", Double($0.allocatedSize) / 1_048_576)) MB" }
        }
        return each.joined(separator: ", ") + "; all \(device.currentAllocatedSize >> 20) MB"
    }

    func loseTargets() {
        for texture in [piecesTexture, glowTexture].compactMap({ $0 }) + levels { texture.setPurgeableState(.empty) }
    }

    private func wake() {
        guard isResting else { return }
        isResting = false
        var lost = false
        for texture in [piecesTexture, glowTexture].compactMap({ $0 }) + levels where texture.setPurgeableState(.nonVolatile) == .empty { lost = true }
        // Their memory was taken, so they're made again. That only happens when the Mac is short of it.
        if lost { piecesTexture = nil }
    }

    private func pass(_ commands: MTLCommandBuffer, target: MTLTexture, also second: MTLTexture? = nil, clear: Bool = false, _ body: (MTLRenderCommandEncoder) -> Void) {
        let d = MTLRenderPassDescriptor()
        for (index, texture) in [target, second].compactMap({ $0 }).enumerated() {
            d.colorAttachments[index].texture = texture
            d.colorAttachments[index].loadAction = clear ? .clear : .dontCare
            d.colorAttachments[index].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            d.colorAttachments[index].storeAction = .store
        }
        guard let e = commands.makeRenderCommandEncoder(descriptor: d) else { return }
        body(e)
        e.endEncoding()
    }

    func encode(into commands: MTLCommandBuffer, target: MTLTexture, uniforms: UniformsGPU) {
        let width = target.width, height = target.height
        wake()
        prepareTargets(width: width, height: height)
        guard let pieces = piecesTexture, let glow = glowTexture else { return }
        var u = uniforms

        pass(commands, target: pieces, also: glow, clear: true) { e in
            e.setRenderPipelineState(segmentPipeline)
            e.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
            e.setVertexBytes(&u, length: MemoryLayout<UniformsGPU>.stride, index: 1)
            e.setVertexBuffer(emphasisBuffer, offset: emphasisOffset, index: 2)
            e.setFragmentBytes(&u, length: MemoryLayout<UniformsGPU>.stride, index: 1)
            if instanceCount > 0 {
                // Past 1, emphasis lifts a piece outward, and while a tint shows a lit piece may be drawn wider than its
                // place: both have to lie over their neighbours. So every piece is in one of three layers by how lit it
                // is, and each pass draws all the pieces with the shader leaving out the ones that aren't in its layer.
                // The piece pointed at is a layer of its own, over those. One draw while nothing is lit, four at most,
                // however many pieces are.
                u.litAbove = liftLit ? Self.litAbove : 1
                let top = top.flatMap { $0 < instanceCount ? $0 : nil }
                u.top = top.map(Float.init) ?? -1
                var layers: [Float] = [0]
                if mostLit > u.litAbove, u.litAbove < 1 { layers.append(1) }
                if mostLit > 1 { layers.append(2) }
                for layer in layers {
                    u.layer = layer
                    e.setVertexBytes(&u, length: MemoryLayout<UniformsGPU>.stride, index: 1)
                    e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instanceCount)
                }
                if let top {
                    u.layer = 3
                    e.setVertexBytes(&u, length: MemoryLayout<UniformsGPU>.stride, index: 1)
                    e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1, baseInstance: top)
                }
            }
        }

        // Down through a chain of smaller and smaller copies, then back up: a wide glow from few samples.
        var source = glow
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
            e.setRenderPipelineState((target.pixelFormat == Self.narrowOutputFormat ? narrowCompositePipeline : nil) ?? compositePipeline)
            e.setFragmentTexture(pieces, index: 0)
            e.setFragmentTexture(levels[1], index: 1)
            e.setFragmentTexture(levels[levels.count - 2], index: 2)
            e.setFragmentBytes(&u, length: MemoryLayout<UniformsGPU>.stride, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    var commandQueue: MTLCommandQueue { queue }
}
