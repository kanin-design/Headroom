import Foundation

/// For recording a demo on made-up disks, and only in a scripted run. `--demo-scale 200` multiplies every size a scan reads,
/// and each disk's own size, so a few gigabytes on a disk image read as a full Mac. `--demo-disks /a:/b` makes those the
/// only disks, in that order, so a recording never shows your own.
enum Demo {
    static let scale = scale(in: CommandLine.arguments)
    static let disks = disks(in: CommandLine.arguments)
    /// The first demo disk plays your Mac's own disk, so its paths read as your home folder's: `~/Movies`.
    static let home = disks?.first

    static func scale(in arguments: [String]) -> UInt64 {
        guard arguments.contains("--script"), let at = arguments.firstIndex(of: "--demo-scale"), at + 1 < arguments.count,
              let factor = UInt64(arguments[at + 1]), factor > 1 else { return 1 }
        return factor
    }

    static func disks(in arguments: [String]) -> [String]? {
        guard arguments.contains("--script"), let at = arguments.firstIndex(of: "--demo-disks"), at + 1 < arguments.count else { return nil }
        let paths = arguments[at + 1].split(separator: ":").map(String.init).filter { !$0.isEmpty }
        return paths.isEmpty ? nil : paths
    }

    /// A size as the demo shows it.
    @inline(__always) static func scaled(_ bytes: UInt64, by factor: UInt64 = scale) -> UInt64 {
        guard factor > 1 else { return bytes }
        let (product, overflow) = bytes.multipliedReportingOverflow(by: factor)
        return overflow ? .max : product
    }
}
