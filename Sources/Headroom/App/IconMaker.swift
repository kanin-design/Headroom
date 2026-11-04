import AppKit
import Foundation
import simd

/// Draws the app icon with the same renderer as the map, so it's made of the same light.
enum IconMaker {
    static func make(to path: String) {
        guard let renderer = MapRenderer(shaders: URL(fileURLWithPath: "Sources/Headroom/Render/Shaders.metal")) else {
            print("no renderer")
            return
        }
        var generator = SplitMix(state: 41)
        var instances: [SegmentGPU] = []
        let hole: Float = 0.30
        let edges: [Float] = [hole, 0.335, 0.56, 0.75, 0.90, 1.0]
        func piece(_ a0: Float, _ a1: Float, _ ring: Int, _ lab: Lab, style: Float = 0) {
            let g = SIMD4<Float>(a0, a1, edges[ring], edges[ring + 1])
            let c = lab.linearP3
            let color = SIMD4<Float>(c.x, c.y, c.z, 1)
            instances.append(SegmentGPU(from: g, to: g, colorFrom: color, colorTo: color, params: SIMD4(style, generator.next(), 0, 0)))
        }
        let shares: [(Float, Kind)] = [(0.36, .video), (0.20, .audio), (0.13, .model), (0.11, .app), (0.05, .cache)]
        var angle: Float = 0
        let scale: Float = 2 * .pi
        for (share, kind) in shares {
            let sweep = share * scale
            let color = Palette.color(kind)
            piece(angle, angle + sweep, 0, color)
            piece(angle, angle + sweep, 1, color)
            // Each one splits as it goes outward, unevenly, the way real folders do.
            var a2 = angle
            let parts2 = 2 + Int(share * 12)
            for p in 0..<parts2 {
                let remaining = angle + sweep - a2
                let s2 = p == parts2 - 1 ? remaining : remaining * (0.42 + 0.2 * generator.next())
                piece(a2, a2 + s2, 2, color)
                if generator.next() > 0.15 || p == 0 {
                    var a3 = a2
                    let parts3 = 2 + Int(generator.next() * 3)
                    for q in 0..<parts3 {
                        let rest = a2 + s2 - a3
                        let s3 = q == parts3 - 1 ? rest : rest * (0.4 + 0.25 * generator.next())
                        if generator.next() > 0.22 { piece(a3, a3 + s3, 3, color) }
                        a3 += s3
                    }
                }
                a2 += s2
            }
            angle += sweep
        }
        let free = SIMD4<Float>(angle, 2 * .pi, hole, 1)
        instances.append(SegmentGPU(from: free, to: free, colorFrom: SIMD4(0, 0, 0, 1), colorTo: SIMD4(0, 0, 0, 1), params: SIMD4(1, 0, 0, 0)))

        renderer.setInstances(instances)
        renderer.writeEmphasis([Float](repeating: 0, count: instances.count))
        let size = 1024
        var u = UniformsGPU()
        u.viewport = SIMD2(Float(size), Float(size))
        u.center = SIMD2(Float(size) * 0.5, Float(size) * 0.5)
        u.radius = 366
        u.scale = 4
        u.bloom = 1.25
        u.hideScale = 1
        let raw = path + ".raw.png"
        renderer.renderPNG(to: raw, width: size, height: size, uniforms: u)

        // Apple's icon shape: a continuous rounded square, inside the standard margin of the canvas.
        guard let source = NSImage(contentsOfFile: raw)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let inset: CGFloat = 100
        let rect = CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 186, yRadius: 186).cgPath
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -14), blur: 32, color: CGColor(gray: 0, alpha: 0.42))
        context.addPath(shape)
        context.setFillColor(CGColor(gray: 0.02, alpha: 1))
        context.fillPath()
        context.restoreGState()
        context.addPath(shape)
        context.clip()
        context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
        // A fine edge of light all round, as on a real object.
        context.resetClip()
        context.addPath(shape)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.13))
        context.setLineWidth(2.5)
        context.strokePath()
        guard let image = context.makeImage(),
              let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(out, image, nil)
        CGImageDestinationFinalize(out)
        try? FileManager.default.removeItem(atPath: raw)
        print("icon \(path)")
    }
}

private struct SplitMix {
    var state: UInt64
    mutating func next() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24)
    }
}
