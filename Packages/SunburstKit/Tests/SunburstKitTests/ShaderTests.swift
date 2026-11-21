import Metal
import XCTest
@testable @_spi(Diagnostics) import SunburstKit

/// The ring's shaders are compiled when the app starts, so a mistake in them only shows as a ring that isn't there. These
/// compile them here, and check that the numbers Swift hands the GPU each frame sit where the shaders read them.
final class ShaderTests: XCTestCase {
    private var source: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SunburstKit/Shaders.metal")
    }

    /// A GPU to draw with, or the test is skipped: some machines that build and test have none.
    private func device() throws -> MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice() ?? { throw XCTSkip("no GPU here") }())
    }

    func testTheBuiltInShadersAreTheSourceFile() throws {
        let file = try String(contentsOf: source, encoding: .utf8)
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .newlines) }
        XCTAssertEqual(trimmed(ShaderSource.metal), trimmed(file), "Shaders.metal changed: run Scripts/embed-shaders.sh")
    }

    func testTheShadersCompile() throws {
        let device = try device()
        XCTAssertNotNil(SunburstRenderer(device: device), "the built-in shaders compile and make their pipelines")
        XCTAssertNotNil(SunburstRenderer(device: device, shaders: source), "and so does their source file")
    }

    func testTheFrameNumbersAreWhereTheShadersReadThem() throws {
        let device = try device()
        let library = try device.makeLibrary(source: ShaderSource.metal, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "segment_vertex")
        d.fragmentFunction = library.makeFunction(name: "segment_fragment")
        d.colorAttachments[0].pixelFormat = .rgba16Float
        d.colorAttachments[1].pixelFormat = .rgba16Float
        var reflection: MTLAutoreleasedRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
        let binding = try XCTUnwrap(reflection?.vertexBindings.first { $0.index == 1 && $0.type == .buffer } as? MTLBufferBinding)
        let members = try XCTUnwrap(binding.bufferStructType?.members)
        let swift: [String: Int?] = [
            "viewport": MemoryLayout<UniformsGPU>.offset(of: \.viewport), "center": MemoryLayout<UniformsGPU>.offset(of: \.center),
            "radius": MemoryLayout<UniformsGPU>.offset(of: \.radius), "t": MemoryLayout<UniformsGPU>.offset(of: \.t),
            "scale": MemoryLayout<UniformsGPU>.offset(of: \.scale), "dim": MemoryLayout<UniformsGPU>.offset(of: \.dim),
            "liftPixels": MemoryLayout<UniformsGPU>.offset(of: \.liftPixels), "bloom": MemoryLayout<UniformsGPU>.offset(of: \.bloom),
            "headroom": MemoryLayout<UniformsGPU>.offset(of: \.headroom), "hideScale": MemoryLayout<UniformsGPU>.offset(of: \.hideScale),
            "restSaturation": MemoryLayout<UniformsGPU>.offset(of: \.restSaturation), "glowAtRest": MemoryLayout<UniformsGPU>.offset(of: \.glowAtRest),
            "minLit": MemoryLayout<UniformsGPU>.offset(of: \.minLit),
            "layer": MemoryLayout<UniformsGPU>.offset(of: \.layer), "litAbove": MemoryLayout<UniformsGPU>.offset(of: \.litAbove),
            "top": MemoryLayout<UniformsGPU>.offset(of: \.top), "dither": MemoryLayout<UniformsGPU>.offset(of: \.dither),
            "dialSides": MemoryLayout<UniformsGPU>.offset(of: \.dialSides),
            "tint": MemoryLayout<UniformsGPU>.offset(of: \.tint),
        ]
        XCTAssertEqual(members.count, swift.count, "the same numbers on both sides")
        for m in members { XCTAssertEqual(swift[m.name] ?? nil, m.offset, "\(m.name) is where the shaders read it") }
        XCTAssertEqual(binding.bufferDataSize, MemoryLayout<UniformsGPU>.size, "and the whole is the same size")
    }

    /// A folder and one of the folders in it, the outer one just left by the pointer and still lifted, the inner one
    /// pointed at now and growing out over it. Draws them and gives the colour where the inner one has grown to.
    private func colourWhereTheInnerOneGrows(top: Int?) throws -> SIMD4<Float> {
        let device = try device()
        try XCTSkipUnless(device.hasUnifiedMemory, "reads the picture straight from the GPU's memory")
        let renderer = try XCTUnwrap(SunburstRenderer(device: device))
        let red = SIMD4<Float>(1, 0, 0, 1), blue = SIMD4<Float>(0, 0, 1, 1)
        let inner = SIMD4<Float>(0.5, 1.5, 0.3, 0.5), outer = SIMD4<Float>(0.5, 1.5, 0.5, 0.7)
        renderer.setInstances([SegmentGPU(from: inner, to: inner, colorFrom: red, colorTo: red, params: .zero),
                               SegmentGPU(from: outer, to: outer, colorFrom: blue, colorTo: blue, params: .zero)])
        renderer.writeEmphasis([1.5, 1.5], tintShares: [1, 1], top: top)

        let side = 400
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: SunburstRenderer.outputFormat, width: side, height: side, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: d))
        var u = UniformsGPU()
        u.viewport = SIMD2(Float(side), Float(side))
        u.center = SIMD2(200, 200)
        u.radius = 180
        u.scale = 1
        // Under the most a piece this thick may lift: three tenths of its 36 pixels.
        u.liftPixels = 8
        u.bloom = 0
        u.hideScale = 1
        let commands = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        renderer.encode(into: commands, target: target, uniforms: u)
        commands.commit()
        commands.waitUntilCompleted()

        // The inner one ends 90 pixels out and is lifted 4 more. Halfway into that, in the middle of its arc.
        let x = 200 + Int((sin(Float(1)) * 92).rounded()), y = 200 - Int((cos(Float(1)) * 92).rounded())
        var pixel = [Float16](repeating: 0, count: 4)
        target.getBytes(&pixel, bytesPerRow: 4 * MemoryLayout<Float16>.stride, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return SIMD4(Float(pixel[0]), Float(pixel[1]), Float(pixel[2]), Float(pixel[3]))
    }

    func testThePiecePointedAtLiesOverOneThePointerJustLeft() throws {
        let pointedAt = try colourWhereTheInnerOneGrows(top: 0)
        XCTAssertGreaterThan(pointedAt.x, 0.1, "the folder pointed at is drawn where it has grown to")
        XCTAssertGreaterThan(pointedAt.x, pointedAt.z * 4, "and over the folder in it that's still settling back")
        // Without knowing which one is pointed at, the later piece wins: what this is here to prevent.
        let neither = try colourWhereTheInnerOneGrows(top: nil)
        XCTAssertGreaterThan(neither.z, neither.x * 4, "the check can tell the two apart")
    }
}
