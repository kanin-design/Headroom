import Testing
@testable import SunburstKit

@Suite("Palettes")
struct PaletteTests {
    @Test("Spectrum is the colours branches always had")
    func spectrumIsUnchanged() {
        for i in 0..<40 {
            #expect(SunburstPalette.spectrum.hue(i) == SunburstHues.hue(i))
            for j in 0..<40 {
                let before = SunburstHues.apart(SunburstHues.hue(i), SunburstHues.hue(j)) < SunburstHues.neighbourGap
                #expect(SunburstPalette.spectrum.tooClose(i, j) == before)
            }
        }
        // A memory keeps the same places whichever way it's asked.
        var byHue = HueMemory(), byPlace = HueMemory()
        var previousHue: Float?, previousPlace: Int?
        for name in (0..<30).map({ "folder \($0)" }) {
            let hue = byHue.hue(for: name, after: previousHue)
            let place = byPlace.index(for: name, after: previousPlace, in: .spectrum)
            #expect(hue == SunburstHues.hue(place))
            previousHue = hue
            previousPlace = place
        }
        #expect(byHue.indices == byPlace.indices)
    }

    @Test("A fixed palette goes round its colours, never the same one twice in a row")
    func fixedGoesRound() {
        let palette = SunburstPalette.colourBlindSafe
        guard case .fixed(let colours) = palette.kind else { Issue.record("not fixed"); return }
        #expect(palette.colour(0).l == colours[0].x && palette.colour(colours.count).l == colours[0].x)
        var memory = HueMemory()
        var previous: Int?
        for name in (0..<25).map({ "branch \($0)" }) {
            let place = memory.index(for: name, after: previous, in: palette)
            if let previous { #expect(place % colours.count != previous % colours.count) }
            previous = place
        }
    }

    @Test("A palette of one colour, or none, still gives every branch a colour")
    func tinyPalettesEnd() {
        for palette in [SunburstPalette.fixed(id: "one", name: "One", [Lab(lch: 0.7, 0.1, 200)]),
                        SunburstPalette.fixed(id: "none", name: "None", [])] {
            var memory = HueMemory()
            var previous: Int?
            for name in ["a", "b", "c"] {
                previous = memory.index(for: name, after: previous, in: palette)
            }
            #expect(memory.indices.count == 3)
        }
    }

    @Test("A dynamic palette keeps to its hues, and neighbours stay apart")
    func dynamicKeepsToItsRange() {
        for palette in [SunburstPalette.cool, .warm] {
            guard case .dynamic(let from, let through) = palette.kind else { continue }
            for i in 0..<50 {
                let h = palette.hue(i)
                #expect(h >= from && h <= through)
            }
            var memory = HueMemory()
            var previous: Int?
            for name in (0..<20).map({ "x\($0)" }) {
                let place = memory.index(for: name, after: previous, in: palette)
                if let previous { #expect(!palette.tooClose(place, previous)) }
                previous = place
            }
        }
    }

    @Test("Every palette's colours can be shown, and ids are unique")
    func everyPaletteIsUsable() {
        #expect(Set(SunburstPalette.all.map(\.id)).count == SunburstPalette.all.count)
        #expect(SunburstPalette.all.first == .spectrum)
        for palette in SunburstPalette.all {
            for i in 0..<12 {
                let c = palette.colour(i)
                #expect(c.l > 0.45 && c.l < 0.95, "\(palette.name) \(i) is light enough to read on the dark ring")
                let p3 = c.linearP3
                #expect(max(p3.x, p3.y, p3.z) > 0.05)
            }
        }
    }
}
