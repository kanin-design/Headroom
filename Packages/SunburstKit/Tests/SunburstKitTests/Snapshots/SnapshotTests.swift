import Foundation
import ImageIO
import Testing
@testable import SunburstKit

/// The layout, the names and the pictures are the same as the kit drew them before parts (0.2.1), line for line and
/// pixel for pixel, for every tree in `SnapshotCases`. On a GPU other than the one that drew the pictures, such as a CI
/// runner's, they're compared with their edges averaged out (`PictureDifference`).
@Suite("Snapshots")
@MainActor
struct SnapshotTests {
    private nonisolated static let baseline = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Baseline")

    /// Whether this GPU drew the baseline's pictures (`Baseline/gpu.txt`). Another one draws edges a little differently,
    /// so its pictures are compared less closely.
    nonisolated static var drewTheBaseline: Bool {
        let drew = try? String(contentsOf: baseline.appendingPathComponent("gpu.txt"), encoding: .utf8)
        return drew?.trimmingCharacters(in: .whitespacesAndNewlines) == SnapshotCases.gpu
    }

    /// Where a picture that differs is kept to look at: SNAPSHOT_FAILURES, which CI uploads, or else the temporary folder.
    private nonisolated static var failures: URL {
        ProcessInfo.processInfo.environment["SNAPSHOT_FAILURES"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
    }

    @Test("Every case is laid out and named as before")
    func everyCase() throws {
        var differ: [String] = []
        for c in SnapshotCases.all {
            let expected = try String(contentsOf: Self.baseline.appendingPathComponent("\(c.name).txt"), encoding: .utf8)
            // The picture's hash line is checked by its pixels, on the GPU that drew it.
            let text = SnapshotCases.dump(c).0.split(separator: "\n").filter { !$0.hasPrefix("picture ") }.joined(separator: "\n") + "\n"
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

    @Test("Every picture is drawn as before")
    func everyPicture() throws {
        let closely = Self.drewTheBaseline
        var differ: [String] = []
        for c in SnapshotCases.all where c.picture {
            guard let pic = SnapshotCases.picture(SnapshotCases.dump(c).1) else { continue }
            let was = try Data(contentsOf: Self.baseline.appendingPathComponent("\(c.name).png"))
            let difference = try PictureDifference(was, pic.png)
            if !difference.isSame(closely: closely) {
                let out = Self.failures.appendingPathComponent("snapshot-\(c.name).png")
                try? FileManager.default.createDirectory(at: Self.failures, withIntermediateDirectories: true)
                try? pic.png.write(to: out)
                differ.append("\(c.name): picture differs: \(difference), see \(out.path)")
            }
        }
        #expect(differ.isEmpty, Comment(rawValue: differ.joined(separator: "\n")))
    }

    @Test("A piece in another colour is caught on any GPU")
    func anotherColour() throws {
        let c = try #require(SnapshotCases.all.first { $0.picture })
        var layout = SnapshotCases.dump(c).1
        // One piece of the second ring, a tenth of a turn wide or less: not the biggest thing in the picture.
        let piece = try #require(layout.pieces.indices.first {
            layout.pieces[$0].ring == 1 && layout.pieces[$0].sweep > 0.15 && layout.pieces[$0].sweep < 0.63
        })
        let was = layout.pieces[piece].color
        layout._pieces[piece].color = SIMD3(was.z, was.x, was.y)
        guard let pic = SnapshotCases.picture(layout) else { return }
        let before = try Data(contentsOf: Self.baseline.appendingPathComponent("\(c.name).png"))
        let difference = try PictureDifference(before, pic.png)
        #expect(!difference.isSame(closely: false), "\(difference)")
    }
}

/// How two pictures of the same size differ, in 8-bit steps of any channel.
struct PictureDifference: CustomStringConvertible {
    /// How many pixels differ at all.
    var count = 0
    /// By how much at most, pixel by pixel.
    var most = 0
    /// By how much at most, between the pictures averaged over blocks of 4 by 4 pixels: edges drawn a little differently
    /// average out, and anything a person could see doesn't.
    var mostAveraged = 0

    static let block = 4

    init(_ a: Data, _ b: Data) throws {
        let (x, width, height) = try Self.pixels(a), (y, widthB, heightB) = try Self.pixels(b)
        guard width == widthB, height == heightB else {
            (count, most, mostAveraged) = (Int.max, 255, 255)
            return
        }
        let across = (width + Self.block - 1) / Self.block
        var sums = [Int](repeating: 0, count: across * ((height + Self.block - 1) / Self.block) * 4)
        for row in 0..<height {
            for column in 0..<width {
                let i = (row * width + column) * 4, cell = (row / Self.block * across + column / Self.block) * 4
                var off = 0
                for channel in 0..<4 {
                    let d = Int(x[i + channel]) - Int(y[i + channel])
                    sums[cell + channel] += d
                    off = max(off, abs(d))
                }
                if off > 0 { count += 1 }
                most = max(most, off)
            }
        }
        let area = Self.block * Self.block
        mostAveraged = sums.reduce(0) { max($0, (abs($1) + area / 2) / area) }
    }

    /// Whether the pictures count as the same.
    ///
    /// Closely, on the GPU that drew the first: the shaders are built with fast maths, so a change anywhere in them can move
    /// a value by the last bit and a pixel by one step of brightness. No pixel may be off by more than that, and only a few
    /// at all; anything a person could see is far more.
    ///
    /// Otherwise, on another GPU: it rounds edges a little differently (GitHub's runners against an M5: about a pixel in 500
    /// off, by up to 32 steps), so the pictures are compared averaged over small blocks, where that comes to a few steps.
    /// A piece in another colour, a piece gone or a ring a pixel out of place moves whole blocks by far more than the 24
    /// steps allowed. It can't see a slight change of colour, which the close comparison is for.
    func isSame(closely: Bool) -> Bool {
        closely ? most <= 1 && count <= 32 : mostAveraged <= 24
    }

    var description: String {
        "\(count) pixels by up to \(most), and by up to \(mostAveraged) averaged over \(Self.block) by \(Self.block)"
    }

    private static func pixels(_ data: Data) throws -> (bytes: [UInt8], width: Int, height: Int) {
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
        return (out, image.width, image.height)
    }
}
