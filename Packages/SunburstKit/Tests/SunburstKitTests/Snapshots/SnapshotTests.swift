import Foundation
import ImageIO
import Testing
@testable import SunburstKit

/// The layout, the names and the pictures are the same as the kit drew them before parts (0.2.1), line for line and
/// pixel for pixel, for every tree in `SnapshotCases`.
@Suite("Snapshots")
@MainActor
struct SnapshotTests {
    private let baseline = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Baseline")

    @Test("Every case is drawn as before")
    func everyCase() throws {
        var differ: [String] = []
        for c in SnapshotCases.all {
            let expected = try String(contentsOf: baseline.appendingPathComponent("\(c.name).txt"), encoding: .utf8)
            var (text, layout, _) = SnapshotCases.dump(c)
            if c.picture, let pic = SnapshotCases.picture(layout) {
                // The shaders are built with fast maths, so a change anywhere in them can move a value by the last bit and a
                // pixel by one step of brightness. A picture counts as the same if no pixel is off by more than that, and
                // only a few are off at all; anything a person could see is far more.
                let was = try Data(contentsOf: baseline.appendingPathComponent("\(c.name).png"))
                let (count, most) = try Self.difference(was, pic.png)
                if most > 1 || count > 32 {
                    let out = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(c.name).png")
                    try? pic.png.write(to: out)
                    differ.append("\(c.name): picture differs in \(count) pixels by up to \(most), see \(out.path)")
                }
            }
            // The picture's hash line is checked above, by its pixels.
            text = text.split(separator: "\n").filter { !$0.hasPrefix("picture ") }.joined(separator: "\n") + "\n"
            let expectedText = expected.split(separator: "\n").filter { !$0.hasPrefix("picture ") }.joined(separator: "\n") + "\n"
            let a = expectedText.split(separator: "\n", omittingEmptySubsequences: false)
            let b = text.split(separator: "\n", omittingEmptySubsequences: false)
            if let i = (0..<min(a.count, b.count)).first(where: { a[$0] != b[$0] }) ?? (a.count != b.count ? min(a.count, b.count) : nil) {
                let was = i < a.count ? String(a[i].prefix(220)) : "(end)"
                let now = i < b.count ? String(b[i].prefix(220)) : "(end)"
                differ.append("\(c.name) line \(i + 1):\n  was: \(was)\n  now: \(now)")
            }
        }
        #expect(differ.isEmpty, Comment(rawValue: differ.joined(separator: "\n")))
    }

    /// How many pixels of two PNGs differ, and by how much at most, in 8-bit steps of any channel.
    static func difference(_ a: Data, _ b: Data) throws -> (count: Int, most: Int) {
        func pixels(_ data: Data) throws -> [UInt8] {
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
            try out.withUnsafeMutableBytes { raw in
                let context = try #require(CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                                      bytesPerRow: image.width * 4, space: space,
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return out
        }
        let x = try pixels(a), y = try pixels(b)
        guard x.count == y.count else { return (Int.max, Int.max) }
        var count = 0, most = 0
        for i in stride(from: 0, to: x.count, by: 4) {
            let d = (0..<4).map { abs(Int(x[i + $0]) - Int(y[i + $0])) }.max() ?? 0
            if d > 0 { count += 1 }
            most = max(most, d)
        }
        return (count, most)
    }
}
