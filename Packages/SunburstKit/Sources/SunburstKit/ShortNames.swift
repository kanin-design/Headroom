import Foundation
import os

/// Shorter ways to write names that sit side by side: each the real name, cut with "…" where its neighbours, or the
/// folders it's in, already say the same, so the part that tells it apart stays. Among a season's episodes,
/// "Show (2021) - S01E03 - 1080p WEB-DL.mkv" can be written "Show…S01E03 - 1080p WEB-DL.mkv", "Show…S01E03…mkv", and at
/// the least "Show…S01E03…mkv" with a shorter start. Nothing is written that isn't in the name, in its order: it keeps
/// its start and its extension, it's only cut between words, a bracket pair is never split, and two neighbours never
/// come out the same. A name whose neighbours differ only by a number keeps its middle cut.
///
/// Placing names tries a name's forms longest first and uses the first that fits, so a piece with room says more.
public struct ShortNames: Sendable {
    /// For a piece, its name's forms from longest to shortest, the full name first.
    private var known: [Int: [String]] = [:]

    public init() {}

    /// The forms of the names of `pieces` in a layout. `title` gives a piece's full name, or nil for one that isn't named;
    /// `context` the names of the node in the middle and the folders it's in, which names inside it needn't repeat.
    public init(layout: RingLayout, pieces: some Sequence<Int>, context: [String], title: (Int) -> String?) {
        // Neighbours are the pieces with the same parent: in the first ring, what's directly in the middle.
        var families: [Int32: [(index: Int, name: String)]] = [:]
        for i in pieces {
            let p = layout.pieces[i]
            guard !p.isSmaller, !p.isSpace, let name = title(i), !name.isEmpty else { continue }
            families[p.parent, default: []].append((i, name))
        }
        let outer = context.map(Self.words)
        // What the folders around each family say: the middle's, and each folder between it and them, worked out once for
        // each folder.
        var aroundOf: [Int32: [[String]]] = [-1: outer]
        func around(_ parent: Int32) -> [[String]] {
            if let known = aroundOf[parent] { return known }
            var list = around(layout.pieces[Int(parent)].parent)
            if let name = title(Int(parent)) { list.append(Self.words(name)) }
            aroundOf[parent] = list
            return list
        }
        for (parent, family) in families {
            let forms = Self.forms(family.map(\.name), around: around(parent))
            for (member, list) in zip(family, forms) where list.count > 1 { known[member.index] = list }
        }
    }

    /// A piece's name, then its shorter forms, longest first. Only forms worked out from this same name: a name the app
    /// writes its own way is left whole.
    public func forms(of index: Int, full: String) -> [String] {
        guard let list = known[index], list.first == full else { return [full] }
        return list
    }

    /// The forms of names that sit side by side in a list, in the same order: for each, the name itself, then shorter ways
    /// to write it, longest first. `around` is the names of the folders they're in, which the names needn't repeat.
    public static func forms(of names: [String], around: [String] = []) -> [[String]] {
        forms(names, around: around.map(words))
    }

    // MARK: Working them out

    struct Token: Equatable, Sendable {
        var text: String
        var isWord: Bool
    }

    private static let separators = Set(" -_.,()[]{}·–—+")

    /// A name's tokens, split once: names are placed again on every change of picture, and are mostly the same names.
    static func tokens(_ name: String) -> [Token] {
        if let known = split.withLock({ $0[name] }) { return known }
        let made = splitting(name)
        split.withLock { known in
            if known.count > 4096 { known.removeAll(keepingCapacity: true) }
            known[name] = made
        }
        return made
    }

    private static let split = OSAllocatedUnfairLock(initialState: [String: [Token]]())

    private static func splitting(_ name: String) -> [Token] {
        var out: [Token] = []
        var current = ""
        var inWord = false
        let chars = Array(name)
        for (i, ch) in chars.enumerated() {
            // A dash, dot or colon between two digits holds a date, a time or a version together: 2026-11-20, 14.32.07, 1.2.
            let joins = "-.:".contains(ch) && i > 0 && i + 1 < chars.count && chars[i - 1].isNumber && chars[i + 1].isNumber
            let word = joins || !separators.contains(ch)
            if !current.isEmpty, word != inWord {
                out.append(Token(text: current, isWord: inWord))
                current = ""
            }
            current.append(ch)
            inWord = word
        }
        if !current.isEmpty { out.append(Token(text: current, isWord: inWord)) }
        return out
    }

    private static func words(_ name: String) -> [String] {
        if let known = wordCache.withLock({ $0[name] }) { return known }
        let made = tokens(name).filter(\.isWord).map { $0.text.lowercased() }
        wordCache.withLock { known in
            if known.count > 4096 { known.removeAll(keepingCapacity: true) }
            known[name] = made
        }
        return made
    }

    private static let wordCache = OSAllocatedUnfairLock(initialState: [String: [String]]())

    /// The forms of each of these names, which sit side by side: each list starts with the name itself, and each form after
    /// it is the name with more cut out.
    static func forms(_ names: [String], around: [[String]]) -> [[String]] {
        let all = names.map(tokens)
        // Names that start with the same word are a family of their own: photos among notes, episodes among extras.
        var byFirst: [String: [Int]] = [:]
        for (i, t) in all.enumerated() {
            if let first = t.first(where: \.isWord) { byFirst[first.text.lowercased(), default: []].append(i) }
        }
        // What each family shares, worked out once for the family.
        var sharedOf: [String: (prefix: Int, suffix: Int)] = [:]
        for (first, kin) in byFirst where kin.count >= 2 { sharedOf[first] = Self.shared(kin.map { all[$0] }) }
        var result = names.map { [$0] }
        for (i, t) in all.enumerated() {
            let first = t.first(where: \.isWord)?.text.lowercased() ?? ""
            let shared = sharedOf[first] ?? (prefix: 0, suffix: 0)
            let ext = Self.extensionLength(t)
            // What tells it apart starts past what its neighbours share or the folders around it say, and ends before
            // what its neighbours share at the end.
            let start = max(shared.prefix, Self.repeated(t, around: around))
            let end = t.count - max(shared.suffix, ext)
            guard let firstWord = t.firstIndex(where: \.isWord), start < end else { continue }
            let head = firstWord + 1
            // A number or a year alone isn't what a thing is called: such a name is only cut in the middle.
            guard Self.join(Array(t[start..<end])).contains(where: \.isLetter) else { continue }
            let cutsStart = start > head && t[head..<start].contains(where: \.isWord)
            let cutsEnd = ext > 0 && end < t.count - ext && t[end..<(t.count - ext)].contains(where: \.isWord)
            var list = [names[i]]
            func add(_ form: String) {
                if form.count < (list.last ?? "").count, !list.contains(form) { list.append(form) }
            }
            let from = cutsStart ? [0..<head, start..<t.count] : [0..<t.count]
            if cutsStart { add(Self.elide(t, keeping: from)) }
            if cutsEnd {
                let kept = (cutsStart ? [0..<head, start..<end] : [0..<end]) + [(t.count - 1)..<t.count]
                add(Self.elide(t, keeping: kept))
            }
            // At the least, a shorter start: enough of the first word to know it by.
            let word = t[firstWord].text
            if list.count > 1, word.count >= 7, let last = list.last {
                let headText = t[0..<head].map(\.text).joined()
                if last.hasPrefix(headText + "…") {
                    add(t[0..<firstWord].map(\.text).joined() + String(word.prefix(word.count >= 10 ? 5 : 4)) + last.dropFirst(headText.count))
                }
            }
            result[i] = list
        }
        // Two neighbours that would read the same keep their longer forms.
        var seen: [String: Int] = [:]
        for list in result { for form in list.dropFirst() { seen[form.lowercased(), default: 0] += 1 } }
        return result.map { list in [list[0]] + list.dropFirst().filter { seen[$0.lowercased()] == 1 } }
    }

    /// The kept stretches of a name, in order, with "…" where what lies between them is left out, and no separator left
    /// hanging at a cut.
    private static func elide(_ t: [Token], keeping ranges: [Range<Int>]) -> String {
        let cut = CharacterSet(charactersIn: " -_.,·–—+")
        var out = ""
        let kept = ranges.filter { !$0.isEmpty }
        for (k, range) in kept.enumerated() {
            var piece = t[range].map(\.text).joined()
            if k > 0 { piece = String(piece.drop { $0.unicodeScalars.allSatisfy(cut.contains) }) }
            if k < kept.count - 1 {
                while let last = piece.last, last.unicodeScalars.allSatisfy(cut.contains) { piece.removeLast() }
            }
            out += (k > 0 ? "…" : "") + piece
        }
        return out
    }

    /// How many tokens all these names share at the start and at the end, whole tokens only, leaving each at least one word
    /// in between.
    private static func shared(_ names: [[Token]]) -> (prefix: Int, suffix: Int) {
        guard let first = names.first else { return (0, 0) }
        let least = names.map(\.count).min() ?? 0
        var prefix = 0
        while prefix < least, names.allSatisfy({ $0[prefix] == first[prefix] }) { prefix += 1 }
        var suffix = 0
        while suffix < least - prefix, names.allSatisfy({ $0[$0.count - 1 - suffix] == first[first.count - 1 - suffix] }) { suffix += 1 }
        // A word or the separators around it may not be split between the shared part and the middle: back off to where the
        // middle starts and ends on a word.
        func hasWord(_ t: [Token]) -> Bool { t[prefix..<(t.count - suffix)].contains(where: \.isWord) }
        while prefix > 0, !names.allSatisfy(hasWord) { prefix -= 1 }
        while suffix > 0, !names.allSatisfy(hasWord) { suffix -= 1 }
        // Nor may a pair of brackets: "(2020)" is kept whole, never "(2020" with the ")" counted as shared.
        func opens(_ t: [Token]) -> Int {
            t[prefix..<(t.count - suffix)].reduce(0) { n, token in
                n + token.text.filter { "([{".contains($0) }.count - token.text.filter { ")]}".contains($0) }.count
            }
        }
        while suffix > 0, names.contains(where: { opens($0) > 0 }) { suffix -= 1 }
        while prefix > 0, names.contains(where: { opens($0) < 0 }) { prefix -= 1 }
        return (prefix, suffix)
    }

    /// How many tokens at the start of a name say what a folder around it is already called, with the separators after them.
    private static func repeated(_ t: [Token], around: [[String]]) -> Int {
        var best = 0
        for context in around where !context.isEmpty {
            var at = 0, matched = 0
            while at < t.count, matched < context.count {
                if t[at].isWord {
                    guard t[at].text.lowercased() == context[matched] else { break }
                    matched += 1
                }
                at += 1
            }
            guard matched == context.count else { continue }
            // The separators after it go too, as long as a word is left.
            while at < t.count, !t[at].isWord { at += 1 }
            if at < t.count, at > best { best = at }
        }
        return best
    }

    /// 2 when a name ends in an extension: a dot and a short word after a word before it.
    private static func extensionLength(_ t: [Token]) -> Int {
        guard t.count >= 3, let last = t.last, last.isWord, last.text.count <= 5, t[t.count - 2].text == "." else { return 0 }
        return 2
    }

    /// Tokens back into text, without separators hanging at either end.
    private static func join(_ t: [Token]) -> String {
        t.map(\.text).joined().trimmingCharacters(in: CharacterSet(charactersIn: " -_.,·–—+"))
    }
}
