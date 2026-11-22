import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a thing is, at a glance, above its name in the middle of the ring: an app's own icon, or a symbol for its kind.
enum CentreIcon: Equatable {
    case symbol(String)
    /// An app, drawn with its own icon, by its path.
    case app(String)
}

extension AppModel {
    /// The icon for a node of the tree on screen.
    func centreIcon(_ node: UInt32) -> CentreIcon? {
        guard let tree else { return nil }
        if node == 0 { return .symbol(tree.isBoot || pair?.tree === tree ? "internaldrive" : "externaldrive") }
        if let pair, pair.tree === tree {
            if node == pair.macSide { return .symbol("laptopcomputer") }
            if node == pair.driveSide { return .symbol("externaldrive") }
        }
        if tree.isGhost(node) { return .symbol("externaldrive") }
        if node == tree.free { return .symbol("circle.dashed") }
        if node == tree.hidden { return .symbol("eye.slash") }
        if node == tree.home { return .symbol("house") }
        let n = tree.nodes[Int(node)]
        if n.has(NodeFlag.synthetic) { return .symbol("gearshape") }
        let name = displayName(node)
        guard n.has(NodeFlag.directory) else { return .symbol(Self.fileSymbol(name)) }
        if name.hasSuffix(".app"), let path = tree.path(node) { return .app(path) }
        if let special = Self.folderSymbols[name], name == "Applications" || n.parent == tree.home { return .symbol(special) }
        return .symbol(name == ".Trash" ? "trash" : "folder")
    }

    /// The folders in your home folder that the Finder gives an icon of their own, and Applications.
    private static let folderSymbols = [
        "Desktop": "menubar.dock.rectangle", "Documents": "doc.text", "Downloads": "arrow.down.circle", "Movies": "film",
        "Music": "music.note", "Pictures": "photo", "Library": "building.columns", "Public": "person.2",
        "Applications": "square.grid.2x2",
    ]

    /// A file's kind, from its name: worked out once for each extension.
    static func fileSymbol(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if let known = symbolByExtension[ext] { return known }
        let symbol = symbol(forExtension: ext)
        symbolByExtension[ext] = symbol
        return symbol
    }

    private static var symbolByExtension: [String: String] = [:]

    private static func symbol(forExtension ext: String) -> String {
        // Kinds macOS may not know by name.
        if ["mkv", "webm", "avi", "m2ts", "ts"].contains(ext) { return "film" }
        if ["flac", "opus", "ogg"].contains(ext) { return "waveform" }
        if ["heic", "dng", "cr3", "nef", "arw", "raw"].contains(ext) { return "photo" }
        guard let type = UTType(filenameExtension: ext) else { return "doc" }
        if type.conforms(to: .audiovisualContent) && !type.conforms(to: .audio) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .diskImage) { return "opticaldiscdrive" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

/// An icon in the middle of the ring, quieter than the name under it.
struct CentreIconView: View {
    let icon: CentreIcon
    /// The symbol's point size; an app's icon is drawn a little larger, as icons carry their own margin.
    let size: CGFloat

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
        case .app(let path):
            // Until its own icon is read, a symbol stands in for it.
            if let image = AppIcons.shared.icon(path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * 1.6, height: size * 1.6)
            } else {
                Image(systemName: "app")
                    .font(.system(size: size, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// Apps' icons, each read once, off the main thread: reading one can take long enough to hold up the pointer.
@MainActor
@Observable
final class AppIcons {
    static let shared = AppIcons()

    private var known: [String: NSImage] = [:]
    @ObservationIgnored private var reading: Set<String> = []

    /// The app's icon if it's been read; nil while it's being read.
    func icon(_ path: String) -> NSImage? {
        if let image = known[path] { return image }
        guard !reading.contains(path) else { return nil }
        reading.insert(path)
        Task.detached(priority: .utility) {
            let read = Read(image: NSWorkspace.shared.icon(forFile: path))
            await MainActor.run { AppIcons.shared.keep(read.image, for: path) }
        }
        return nil
    }

    private func keep(_ image: NSImage, for path: String) {
        if known.count > 200 { known.removeAll() }
        known[path] = image
        reading.remove(path)
    }

    /// An icon on its way from the thread that read it.
    private struct Read: @unchecked Sendable { let image: NSImage }
}
