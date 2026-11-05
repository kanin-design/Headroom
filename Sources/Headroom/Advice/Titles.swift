import Foundation

/// Reads what a file name says about what it is. Pure text, so it can be tested with made-up names.
enum Titles {
    struct Episode: Equatable {
        var show: String
        var season: Int
        var episode: Int
    }

    /// Finds `S05E04`, `s5e4` or `5x04`, and takes what's before it as the show's name.
    static func parseEpisode(_ fileName: String) -> Episode? {
        let chars = Array(fileName.utf8)
        func isDigit(_ i: Int) -> Bool { i >= 0 && i < chars.count && chars[i] >= 48 && chars[i] <= 57 }
        func isLetter(_ i: Int) -> Bool { i >= 0 && i < chars.count && ((chars[i] | 0x20) >= 97 && (chars[i] | 0x20) <= 122) }
        func number(_ i: inout Int, _ most: Int) -> Int? {
            var value = 0, count = 0
            while count < most, isDigit(i) {
                value = value * 10 + Int(chars[i] - 48)
                i += 1
                count += 1
            }
            return count > 0 ? value : nil
        }
        var i = 0
        while i < chars.count {
            // S05E04, not inside a longer word.
            if chars[i] | 0x20 == 0x73, !isLetter(i - 1), !isDigit(i - 1), isDigit(i + 1) {
                var at = i + 1
                if let season = number(&at, 2) {
                    while at < chars.count, chars[at] == 0x20 || chars[at] == 0x2E || chars[at] == 0x5F || chars[at] == 0x2D { at += 1 }
                    if at < chars.count, chars[at] | 0x20 == 0x65, isDigit(at + 1) {
                        at += 1
                        if let episode = number(&at, 3), !isDigit(at) {
                            return Episode(show: cleanName(String(decoding: chars[0..<i], as: UTF8.self)), season: season, episode: episode)
                        }
                    }
                }
            }
            // 5x04, with nothing number-like touching it: 1920x1080 isn't an episode.
            if isDigit(i), !isDigit(i - 1), !isLetter(i - 1) {
                var at = i
                if let season = number(&at, 2), !isDigit(at), at < chars.count, chars[at] | 0x20 == 0x78, isDigit(at + 1) {
                    at += 1
                    let start = at
                    // Two digits at least: 4x3 is a shape, not an episode.
                    if let episode = number(&at, 3), at - start >= 2, !isDigit(at), !isLetter(at), episode > 0 {
                        return Episode(show: cleanName(String(decoding: chars[0..<i], as: UTF8.self)), season: season, episode: episode)
                    }
                }
            }
            i += 1
        }
        return nil
    }

    /// `Fjord.Crew.Reserve.` becomes `Fjord Crew Reserve`, and `Show - ` becomes `Show`.
    static func cleanName(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " -–—[]()"))
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        return text
    }

    /// What two spellings of one show have in common.
    static func key(_ name: String) -> String {
        var text = name.lowercased()
        // A year in brackets is part of a folder's name, not part of the show's.
        if let open = text.lastIndex(of: "("), text[open...].contains(")") { text = String(text[..<open]) }
        return String(text.filter { $0.isLetter || $0.isNumber })
    }

    /// The same, for a folder that may be one of two shows with one name: "Doctor Who (1963)" and "Doctor Who (2005)".
    static func folderKey(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func isSeasonFolder(_ name: String) -> Bool {
        let text = name.lowercased().trimmingCharacters(in: .whitespaces)
        if text == "specials" { return true }
        for word in ["season", "sesong", "series", "staffel", "saison", "temporada"] where text.hasPrefix(word) {
            let rest = text.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty, rest.allSatisfy(\.isNumber) { return true }
        }
        if text.count >= 2, text.first == "s", text.dropFirst().allSatisfy(\.isNumber) { return true }
        return false
    }

    /// Folders that hold many unrelated things, whatever's in them right now.
    static func isGeneralFolder(_ name: String) -> Bool {
        ["downloads", "torrents", "complete", "completed", "incomplete", "transmission", "seeding", "media", "movies", "films", "tv", "shows", "series", "video", "videos"].contains(name.lowercased())
    }

    /// Whether a file's name ends in a frame number: `shot_00123.png`. A camera numbers its photos the same way, and those
    /// are nothing like frames, so its names don't count.
    static func isNumberedFrame(_ fileName: String) -> Bool {
        let upper = fileName.uppercased()
        for camera in ["IMG", "DSC", "DSCF", "DSCN", "PXL", "GOPR", "GX0", "MVI", "SAM", "P10", "_DSC", "_MG", "PHOTO", "SCREENSHOT", "SCREEN SHOT"] where upper.hasPrefix(camera) { return false }
        let stem = (fileName as NSString).deletingPathExtension
        var digits = 0
        for ch in stem.reversed() {
            if ch.isNumber { digits += 1 } else { break }
        }
        return digits >= 2
    }

    /// How a number of months reads, for "no sign of use".
    static func monthsText(since date: Date, now: Date = Date()) -> String {
        let days = Int(now.timeIntervalSince(date) / 86_400)
        if days < 14 { return days <= 1 ? "a day" : "\(days) days" }
        if days < 60 { return "\(days / 7) weeks" }
        if days < 730 { return "\(days / 30) months" }
        return "\(days / 365) years"
    }

    static func dayText(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        formatter.dateFormat = sameYear ? "MMM d" : "MMM yyyy"
        return formatter.string(from: date)
    }

    /// How much bigger something is than its neighbours, in words.
    static func timesText(_ ratio: Double) -> String {
        if ratio >= 1.9 {
            let whole = Int(ratio.rounded())
            let close = abs(ratio - ratio.rounded()) < 0.12
            return ratio < ratio.rounded() && !close ? "nearly \(whole)x" : (close ? "\(whole)x" : "over \(Int(ratio))x")
        }
        return "bigger than"
    }
}

/// The text format Transmission keeps its records in.
enum Bencode {
    indirect enum Value {
        case int(Int)
        case bytes(Data)
        case list([Value])
        case dict([String: Value])

        var int: Int? { if case .int(let v) = self { return v } else { return nil } }
        var string: String? { if case .bytes(let d) = self { return String(data: d, encoding: .utf8) } else { return nil } }
        var dict: [String: Value]? { if case .dict(let d) = self { return d } else { return nil } }
    }

    static func parse(_ data: Data) -> Value? {
        let bytes = [UInt8](data)
        var at = 0
        return value(bytes, &at, depth: 0)
    }

    private static func value(_ b: [UInt8], _ at: inout Int, depth: Int) -> Value? {
        guard at < b.count, depth < 32 else { return nil }
        switch b[at] {
        case 0x69: // i123e
            at += 1
            var end = at
            while end < b.count, b[end] != 0x65 { end += 1 }
            guard end < b.count, let v = Int(String(decoding: b[at..<end], as: UTF8.self)) else { return nil }
            at = end + 1
            return .int(v)
        case 0x6C: // list
            at += 1
            var out: [Value] = []
            while at < b.count, b[at] != 0x65 {
                guard let v = value(b, &at, depth: depth + 1) else { return nil }
                out.append(v)
            }
            at += 1
            return .list(out)
        case 0x64: // dict
            at += 1
            var out: [String: Value] = [:]
            while at < b.count, b[at] != 0x65 {
                guard case .bytes(let key)? = value(b, &at, depth: depth + 1), let v = value(b, &at, depth: depth + 1) else { return nil }
                out[String(decoding: key, as: UTF8.self)] = v
            }
            at += 1
            return .dict(out)
        default: // 4:name
            var end = at
            while end < b.count, b[end] != 0x3A { end += 1 }
            guard end < b.count, let count = Int(String(decoding: b[at..<end], as: UTF8.self)), count >= 0, end + 1 + count <= b.count else { return nil }
            let start = end + 1
            at = start + count
            return .bytes(Data(b[start..<at]))
        }
    }
}

/// Steam's text format: `"key"   "value"` on each line.
enum SteamText {
    static func values(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            if parts.count >= 5, out[String(parts[1])] == nil { out[String(parts[1])] = String(parts[3]) }
        }
        return out
    }
}
