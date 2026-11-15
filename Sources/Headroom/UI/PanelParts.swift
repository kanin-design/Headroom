import AppKit
import SwiftUI

// The small pieces the inspector's lists are made of.

/// A file's icon as the Finder shows it. Asking for one reads the disk, and a row asks every time it redraws, which is
/// every time the pointer moves over it: so each is asked for once and kept.
@MainActor
enum FileIcons {
    private static let known = NSCache<NSString, NSImage>()

    static func icon(for path: String) -> NSImage {
        if let found = known.object(forKey: path as NSString) { return found }
        let icon = NSWorkspace.shared.icon(forFile: path)
        known.setObject(icon, forKey: path as NSString)
        return icon
    }
}

struct AppIcon: View {
    let path: String

    var body: some View {
        Image(nsImage: FileIcons.icon(for: path))
            .resizable()
            .frame(width: 17, height: 17)
            .padding(.vertical, -3)
    }
}
