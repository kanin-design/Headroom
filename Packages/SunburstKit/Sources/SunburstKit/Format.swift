import Foundation

/// How sizes are written: three significant digits, in units of 1000, so numbers next to each other line up and read alike:
/// "812 MB", "92.0 GB", "3.20 GB".
public enum SunburstFormat {
    /// "3.20 GB".
    public static func bytes(_ bytes: UInt64) -> String {
        let (value, unit) = splitBytes(bytes)
        return "\(value) \(unit)"
    }

    /// "3.20" and "GB", for showing the unit apart.
    public static func splitBytes(_ bytes: UInt64) -> (value: String, unit: String) {
        var value = Double(bytes)
        var index = 0
        while value >= 999.5 && index < units.count - 1 {
            value /= 1000
            index += 1
        }
        let text: String
        if index == 0 || value >= 99.95 {
            text = String(format: "%.0f", value)
        } else if value >= 9.995 {
            text = String(format: "%.1f", value)
        } else {
            text = String(format: "%.2f", value)
        }
        return (text, units[index])
    }

    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]
}
