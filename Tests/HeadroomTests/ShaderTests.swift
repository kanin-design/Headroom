import Metal
import XCTest
@testable import Headroom

/// The ring's shaders are compiled when the app starts, so a mistake in them only shows as a ring that isn't there. These
/// compile them here, and check that the numbers Swift hands the GPU each frame sit where the shaders read them.
final class ShaderTests: XCTestCase {
    private var source: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Headroom/Render/Shaders.metal")
    }

    func testTheShadersCompile() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no GPU here")
        XCTAssertNotNil(MapRenderer(device: device, shaders: source), "the ring's shaders compile and make their pipelines")
    }

    func testTheFrameNumbersAreWhereTheShadersReadThem() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no GPU here")
        let library = try device.makeLibrary(source: String(contentsOf: source, encoding: .utf8), options: nil)
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
            "headroom": MemoryLayout<UniformsGPU>.offset(of: \.headroom), "ghost": MemoryLayout<UniformsGPU>.offset(of: \.ghost),
            "freeStart": MemoryLayout<UniformsGPU>.offset(of: \.freeStart), "hideScale": MemoryLayout<UniformsGPU>.offset(of: \.hideScale),
            "restSaturation": MemoryLayout<UniformsGPU>.offset(of: \.restSaturation), "glowAtRest": MemoryLayout<UniformsGPU>.offset(of: \.glowAtRest),
            "previewShare": MemoryLayout<UniformsGPU>.offset(of: \.previewShare), "ghostCount": MemoryLayout<UniformsGPU>.offset(of: \.ghostCount),
            "freeOuter": MemoryLayout<UniformsGPU>.offset(of: \.freeOuter), "minLit": MemoryLayout<UniformsGPU>.offset(of: \.minLit),
            "previewColor": MemoryLayout<UniformsGPU>.offset(of: \.previewColor), "tint": MemoryLayout<UniformsGPU>.offset(of: \.tint),
            "ghostSlices": MemoryLayout<UniformsGPU>.offset(of: \.ghostSlices),
        ]
        XCTAssertEqual(members.count, swift.count, "the same numbers on both sides")
        for m in members { XCTAssertEqual(swift[m.name] ?? nil, m.offset, "\(m.name) is where the shaders read it") }
        XCTAssertEqual(binding.bufferDataSize, MemoryLayout<UniformsGPU>.size, "and the whole is the same size")
    }
}
