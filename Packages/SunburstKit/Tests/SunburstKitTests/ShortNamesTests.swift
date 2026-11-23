import Testing
@testable import SunburstKit

@Suite("Short names")
struct ShortNamesTests {
    private func forms(_ names: [String], around: [String] = []) -> [[String]] {
        ShortNames.forms(names, around: around.map { ShortNames.tokens($0).filter(\.isWord).map { $0.text.lowercased() } })
    }

    @Test("A season's episodes keep their start, their episode and their extension, cut where they're all alike")
    func episodes() {
        let names = (1...6).map { "Northwater Mysteries (2021) - S01E0\($0) - 1080p WEB-DL.mkv" }
        let out = forms(names, around: ["Season 01", "Northwater Mysteries (2021)", "TV"])
        #expect(out[2] == [names[2], "Northwater…S01E03 - 1080p WEB-DL.mkv", "Northwater…S01E03…mkv", "North…S01E03…mkv"])
        #expect(Set(out.map { $0.last! }).count == 6)
    }

    @Test("Every form is the name itself with parts left out, in order")
    func onlyCuts() {
        let names = (1...4).map { "Lantern (2025) - S01E0\($0) - 4K DV WEB-DL.mkv" }
        for (name, list) in zip(names, forms(names, around: ["Lantern (2025)"])) {
            for form in list {
                // Each stretch between the cuts is in the name, after the one before it.
                var rest = Substring(name)
                for stretch in form.split(separator: "…") {
                    guard let at = rest.range(of: stretch) else { Issue.record("\(form) isn't cut from \(name)"); break }
                    rest = rest[at.upperBound...]
                }
            }
        }
    }

    @Test("Names whose neighbours differ only by a number are left whole")
    func numbers() {
        #expect(forms(["IMG_4821.HEIC", "IMG_4822.HEIC", "notes.txt"]) == [["IMG_4821.HEIC"], ["IMG_4822.HEIC"], ["notes.txt"]])
        #expect(forms(["Track 1.flac", "Track 2.flac"]) == [["Track 1.flac"], ["Track 2.flac"]])
    }

    @Test("Screen recordings keep their start and their date and time")
    func recordings() {
        let out = forms(["Screen Recording 2026-11-20 at 14.32.07.mov", "Screen Recording 2026-11-21 at 09.05.11.mov"])
        #expect(out[0] == ["Screen Recording 2026-11-20 at 14.32.07.mov", "Screen…2026-11-20 at 14.32.07.mov"])
    }

    @Test("Two versions of one episode are told apart by what differs")
    func versions() {
        let out = forms(["Show - S01E03 - 4K DV WEB-DL.mkv", "Show - S01E03 - 1080p WEB-DL.mkv"])
        #expect(out[0].last == "Show…4K DV…mkv" && out[1].last == "Show…1080p…mkv")
    }

    @Test("A lone file only loses what the folder around it already says")
    func lone() {
        let out = forms(["Lanterns (2025) - S01E02 - 4K DV WEB-DL.mkv"], around: ["Lanterns (2025)"])
        #expect(out[0][1] == "Lanterns…S01E02 - 4K DV WEB-DL.mkv")
    }

    @Test("Names with nothing in common stay whole")
    func nothingShared() {
        #expect(forms(["Library", "Media", "dev"]) == [["Library"], ["Media"], ["dev"]])
        #expect(forms(["render-final.mp4", "render-finale.mp4"]) == [["render-final.mp4"], ["render-finale.mp4"]])
    }

    @Test("Brackets stay in pairs, and a year alone isn't a name")
    func brackets() {
        let out = forms(["Harbour Lights (2020)", "Harbour Lights Reunion (2022)", "Lantern (2025)"])
        #expect(out[0] == ["Harbour Lights (2020)"])
        #expect(out[1] == ["Harbour Lights Reunion (2022)", "Harbour…Reunion (2022)", "Harb…Reunion (2022)"])
        #expect(out[2] == ["Lantern (2025)"])
    }

    @Test("A list's names are cut as the ring's are, the folder they're in included")
    func list() {
        let names = ["Lanterns (2025) - S01E02 - 4K DV WEB-DL.mkv", "Lanterns (2025) - S01E05 - 4K DV WEB-DL.mkv"]
        let out = ShortNames.forms(of: names, around: ["Lanterns (2025)"])
        #expect(out.count == 2)
        #expect(out[0].first == names[0])
        #expect(out[0].last == "Lant…S01E02…mkv")
        #expect(out[1].last == "Lant…S01E05…mkv")
        #expect(ShortNames.forms(of: ["Library", "Media"]) == [["Library"], ["Media"]])
    }
}
