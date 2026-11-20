import Foundation
import SwiftUI
import simd

/// Colour in OKLab, which mixes and steps the way the eye expects. Everything ends up in linear Display P3.
public struct Lab: Sendable {
    public var l: Float, a: Float, b: Float

    public init(l: Float, a: Float, b: Float) { self.l = l; self.a = a; self.b = b }

    /// Lightness, chroma and hue in degrees.
    public init(lch l: Float, _ c: Float, _ h: Float) {
        self.l = l
        a = c * cos(h * .pi / 180)
        b = c * sin(h * .pi / 180)
    }

    public var chroma: Float { (a * a + b * b).squareRoot() }

    public var linearP3: SIMD3<Float> {
        let c = unclampedP3
        return SIMD3(max(c.x, 0), max(c.y, 0), max(c.z, 0))
    }

    /// Outside 0...1 means the screen can't show this colour.
    public var unclampedP3: SIMD3<Float> {
        let L = l + 0.3963377774 * a + 0.2158037573 * b
        let M = l - 0.1055613458 * a - 0.0638541728 * b
        let S = l - 0.0894841775 * a - 1.2914855480 * b
        let lc = L * L * L, mc = M * M * M, sc = S * S * S
        let x = 1.2270138511 * lc - 0.5577999807 * mc + 0.2812561490 * sc
        let y = -0.0405801784 * lc + 1.1122568696 * mc - 0.0716766787 * sc
        let z = -0.0763812845 * lc - 0.4214819784 * mc + 1.5861632204 * sc
        let r = 2.4934969 * x - 0.9313836 * y - 0.4027108 * z
        let g = -0.8294890 * x + 1.7626641 * y + 0.0236247 * z
        let bl = 0.0358458 * x - 0.0761724 * y + 0.9568845 * z
        return SIMD3(r, g, bl)
    }

    /// The same colour for SwiftUI, so that panels and the ring match exactly.
    public var swiftUI: Color {
        func encode(_ v: Float) -> Double {
            let x = min(max(v, 0), 1)
            return Double(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)
        }
        let c = linearP3
        return Color(.displayP3, red: encode(c.x), green: encode(c.y), blue: encode(c.z))
    }

    public static func mix(_ x: Lab, _ y: Lab, _ t: Float) -> Lab {
        Lab(l: x.l + (y.l - x.l) * t, a: x.a + (y.a - x.a) * t, b: x.b + (y.b - x.b) * t)
    }
}
