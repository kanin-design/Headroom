import Foundation
import SwiftUI
import simd

/// Colour in OKLab, which mixes and steps the way the eye expects. Everything ends up in linear Display P3.
struct Lab {
    var l: Float, a: Float, b: Float

    init(l: Float, a: Float, b: Float) { self.l = l; self.a = a; self.b = b }

    /// Lightness, chroma and hue in degrees.
    init(lch l: Float, _ c: Float, _ h: Float) {
        self.l = l
        a = c * cos(h * .pi / 180)
        b = c * sin(h * .pi / 180)
    }

    var chroma: Float { (a * a + b * b).squareRoot() }

    var linearP3: SIMD3<Float> {
        let c = unclampedP3
        return SIMD3(max(c.x, 0), max(c.y, 0), max(c.z, 0))
    }

    /// Outside 0...1 means the screen can't show this colour.
    var unclampedP3: SIMD3<Float> {
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
    var swiftUI: Color {
        func encode(_ v: Float) -> Double {
            let x = min(max(v, 0), 1)
            return Double(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)
        }
        let c = linearP3
        return Color(.displayP3, red: encode(c.x), green: encode(c.y), blue: encode(c.z))
    }

    static func mix(_ x: Lab, _ y: Lab, _ t: Float) -> Lab {
        Lab(l: x.l + (y.l - x.l) * t, a: x.a + (y.a - x.a) * t, b: x.b + (y.b - x.b) * t)
    }
}

enum Palette {
    /// One colour per Kind. Hues are spread so that neighbours stay apart, and what you can remove runs hot.
    static let kinds: [Lab] = [
        Lab(lch: 0.45, 0.028, 285),     // other: muted lilac grey
        Lab(lch: 0.58, 0.205, 298),     // video: violet
        Lab(lch: 0.66, 0.195, 352),     // audio: rose
        Lab(lch: 0.79, 0.150, 72),      // images: amber
        Lab(lch: 0.85, 0.105, 100),     // documents: pale gold
        Lab(lch: 0.75, 0.120, 208),     // code: cyan
        Lab(lch: 0.58, 0.170, 258),     // apps: blue
        Lab(lch: 0.65, 0.105, 50),      // archives: copper
        Lab(lch: 0.80, 0.180, 158),     // AI models: jade
        Lab(lch: 0.66, 0.190, 30),      // caches and builds: coral
        Lab(lch: 0.38, 0.014, 255),     // system: slate
    ]

    static func color(_ kind: Kind) -> Lab { kinds[Int(kind.rawValue)] }

    /// Around the wheel, each hue at its own best lightness: yellow can only look yellow when it's light, and blue only
    /// looks blue when it's deep.
    private static let spectrumStops: [(h: Float, l: Float)] = [
        (25, 0.66), (60, 0.74), (95, 0.86), (130, 0.82), (158, 0.80), (195, 0.78), (235, 0.68), (265, 0.58), (298, 0.58),
        (330, 0.62), (355, 0.66),
    ]

    static func spectrumLightness(_ hue: Float) -> Float {
        var h = hue.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        let stops = spectrumStops
        var from = stops[stops.count - 1], to = stops[0]
        var position = h < stops[0].h ? h + 360 : h
        var start = from.h
        var end = to.h + 360
        for i in 0..<stops.count - 1 where h >= stops[i].h && h < stops[i + 1].h {
            from = stops[i]
            to = stops[i + 1]
            start = from.h
            end = to.h
            position = h
        }
        return from.l + (to.l - from.l) * (position - start) / (end - start)
    }

    /// The strongest colour a Display P3 screen can show at this lightness and hue.
    static func strongestChroma(lightness l: Float, hue h: Float) -> Float {
        var low: Float = 0, high: Float = 0.4
        for _ in 0..<9 {
            let middle = (low + high) / 2
            let c = Lab(lch: l, middle, h).unclampedP3
            if min(c.x, c.y, c.z) < 0 || max(c.x, c.y, c.z) > 1 { high = middle } else { low = middle }
        }
        return low
    }

    /// The colour of something made of these kinds. Mixing dulls colours, so chroma is restored toward the strongest
    /// share: a folder that's mostly video still reads as video, and a true mix sits somewhere calmer.
    static func blend(_ bytes: UnsafePointer<UInt32>) -> Lab {
        var total: Float = 0
        for k in 0..<Kind.count { total += Float(bytes[k]) }
        guard total > 0 else { return kinds[0] }
        var l: Float = 0, a: Float = 0, b: Float = 0, chroma: Float = 0
        for k in 0..<Kind.count where bytes[k] > 0 {
            let w = Float(bytes[k]) / total
            l += kinds[k].l * w
            a += kinds[k].a * w
            b += kinds[k].b * w
            chroma += kinds[k].chroma * w
        }
        let mixed = (a * a + b * b).squareRoot()
        if mixed > 0.0001 {
            let restore = min(chroma / mixed, 1.8)
            let target = 1 + (restore - 1) * 0.85
            a *= target
            b *= target
        }
        return Lab(l: l, a: a, b: b)
    }

    /// Heat for the Changes view: from a dull ember up to white-hot.
    static func heat(_ t: Float) -> Lab {
        let x = max(0, min(1, t))
        if x < 0.5 { return Lab.mix(Lab(lch: 0.45, 0.14, 25), Lab(lch: 0.71, 0.225, 38), x * 2) }
        return Lab.mix(Lab(lch: 0.71, 0.225, 38), Lab(lch: 0.93, 0.13, 92), (x - 0.5) * 2)
    }

    /// What grew, in the panel and the middle of Changes. On the ring, the light runs the whole heat scale, by how much.
    static let grew = heat(0.62)

    /// The other end of Changes, what's gone untouched: from a deep blue for a piece that's a little untouched, through azure,
    /// up to pale ice for one that's all untouched. Heat mirrored, as light as it at every step, and cold where it's warm, so
    /// the two read the same way and never look alike.
    static func frost(_ t: Float) -> Lab {
        let x = max(0, min(1, t))
        if x < 0.5 { return Lab.mix(Lab(lch: 0.45, 0.10, 268), Lab(lch: 0.71, 0.145, 238), x * 2) }
        return Lab.mix(Lab(lch: 0.71, 0.145, 238), Lab(lch: 0.93, 0.065, 205), (x - 0.5) * 2)
    }

    /// What's gone untouched, in the panel and the middle of Changes.
    static let untouched = frost(0.62)
    /// Something that shrank.
    static let cool = Lab(lch: 0.62, 0.15, 240)
    /// For pieces that aren't part of the question being asked.
    static let quiet = Lab(lch: 0.27, 0.010, 265)

    /// Each box in Free Up has a colour of its own, and its files wear it on the ring, so the list is the legend.
    enum Box {
        static let trash = Lab(lch: 0.93, 0.012, 250)
        static let quick = Lab(lch: 0.80, 0.205, 150)
        static let models = Lab(lch: 0.79, 0.135, 207)
        static let leftovers = Lab(lch: 0.69, 0.165, 298)
        static let installers = Lab(lch: 0.91, 0.155, 106)
        static let watched = Lab(lch: 0.74, 0.165, 55)
        static let apps = Lab(lch: 0.69, 0.155, 258)
        static let left = Lab(lch: 0.63, 0.035, 255)
        static let used = Lab(lch: 0.85, 0.19, 128)
        static let android = Lab(lch: 0.72, 0.175, 350)
        static let games = Lab(lch: 0.68, 0.185, 25)
        static let repos = Lab(lch: 0.80, 0.09, 300)
        static let films = Lab(lch: 0.82, 0.085, 10)
        static let other = Lab(lch: 0.66, 0.015, 260)
        static let series = Lab(lch: 0.85, 0.165, 92)
        static let screenshots = Lab(lch: 0.78, 0.13, 180)
        static let junk = Lab(lch: 0.80, 0.10, 75)
        /// What you picked yourself on the ring.
        static let hand = Lab(lch: 0.95, 0, 0)
        /// A folder that's all one kind of thing has a colour for each thing, from all around the wheel.
        static let spread: [Lab] = [apps, quick, series, android, models, watched, leftovers, games, used, films, repos, Lab(lch: 0.78, 0.13, 180), installers, Lab(lch: 0.76, 0.09, 250), Lab(lch: 0.86, 0.11, 150), Lab(lch: 0.8, 0.12, 70)]
    }

    /// What can go, in Free Up. The surer it is, the greener and brighter.
    static func reclaim(_ tier: Tier) -> Lab {
        switch tier {
        case .noLoss: Lab(lch: 0.90, 0.205, 155)
        case .rebuilds: Lab(lch: 0.80, 0.225, 150)
        case .redownload: Lab(lch: 0.76, 0.145, 200)
        case .yourCall: Lab(lch: 0.78, 0.150, 75)
        default: quiet
        }
    }
}

/// Decimal units, the ones Finder uses. Three significant figures at most, so numbers stay readable.
func splitBytes(_ bytes: UInt64) -> (value: String, unit: String) {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var value = Double(bytes)
    var index = 0
    while value >= 999.5 && index < units.count - 1 {
        value /= 1000
        index += 1
    }
    let text: String
    if index == 0 || value >= 99.95 { text = String(format: "%.0f", value) }
    else if value >= 9.995 { text = String(format: "%.1f", value) }
    else { text = String(format: "%.2f", value) }
    return (text, units[index])
}

func formatBytes(_ bytes: UInt64) -> String {
    let (value, unit) = splitBytes(bytes)
    return "\(value) \(unit)"
}

func formatCount(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 10_000 { return "\(n / 1000)K" }
    return n.formatted()
}
