import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A film's or a picture's shape, and what's worth knowing about it before deciding: how long it runs, how many pixels it
/// has, how many frames a second. Read from the file itself, off the main thread.
enum LookMedia {
    struct Found: Sendable, Equatable {
        /// Width over height, as it's shown: a film shot upright is taller than it's wide.
        var aspect: CGFloat
        var text: String
    }

    /// Films play in the card itself. What AVFoundation can't play, such as most .mkv, stays a preview.
    static func isFilm(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .movie) else { return false }
        return playable.contains(type.identifier)
    }

    private static let playable = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))

    static func read(_ url: URL) async -> Found? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if isFilm(url) { return await film(url) }
        if type.conforms(to: .image) { return picture(url) }
        return nil
    }

    private static func film(_ url: URL) async -> Found? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let loaded = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate) else { return nil }
        let (size, transform, rate) = loaded
        let shown = size.applying(transform)
        let width = abs(shown.width), height = abs(shown.height)
        guard width >= 1, height >= 1 else { return nil }
        var parts: [String] = []
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 { parts.append(length(seconds)) }
        }
        parts.append("\(Int(width.rounded())) × \(Int(height.rounded()))")
        if rate > 0 { parts.append(frames(rate)) }
        return Found(aspect: width / height, text: parts.joined(separator: " · "))
    }

    private static func picture(_ url: URL) -> Found? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w >= 1, h >= 1 else { return nil }
        // Orientations 5 to 8 are turned a quarter, so the picture is shown the other way round.
        let turned = ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5
        let (width, height) = turned ? (h, w) : (w, h)
        return Found(aspect: width / height, text: "\(Int(width)) × \(Int(height))")
    }

    /// 0:42, 12:05 or 1:02:03.
    static func length(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        let (h, m, s) = (whole / 3600, whole / 60 % 60, whole % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 24 fps, or 29.97 fps.
    static func frames(_ rate: Float) -> String {
        let rounded = (rate * 100).rounded() / 100
        return rounded == rounded.rounded() ? "\(Int(rounded)) fps" : String(format: "%.2f fps", rounded)
    }
}
