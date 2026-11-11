import Foundation

/// What removing something costs you. This is how Free Up sorts everything.
enum Tier: UInt8, Comparable {
    case none = 0
    case noLoss          // a restart, an update or emptying the Trash brings it back
    case rebuilds        // caches and build output: the tool makes it again when it needs to
    case redownload      // models, games, simulators: it comes back, but you wait for it
    case yourCall        // yours to judge: installers, archives, backups, old big files
    case handsOff        // shown and explained, never offered for removal

    static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .none: ""
        case .noLoss: "No loss"
        case .rebuilds: "Rebuilds itself"
        case .redownload: "Re-downloadable"
        case .yourCall: "Review first"
        case .handsOff: "Managed by macOS"
        }
    }

    var promise: String {
        switch self {
        case .none: ""
        case .noLoss: "Nothing is lost."
        case .rebuilds: "Made again when needed."
        case .redownload: "Comes back, but you wait for the download."
        case .yourCall: "Only you know if these still matter."
        case .handsOff: "macOS looks after this."
        }
    }
}

/// The box something is listed under in Free Up: what a person would call that kind of thing. One list, so a new kind of
/// thing is a new rule or a new finder that names its box, and nothing else has to know.
enum BoxKind: String, CaseIterable {
    /// The Trash has nothing to open, so it's one row with a tick of its own.
    case trash
    case caches, junk, developer, models, games, apps, removedApps, backups, installers, screenshots, leftovers, largest
    /// Found, and used elsewhere, but not listed in Free Up: films and series are yours to keep.
    case media
    case other
}

struct Rule {
    var title: String
    var detail: String
    var tier: Tier
    var kind: Kind? = nil
    /// A command that does this better than moving files to the Trash.
    var command: String? = nil
    /// Moving the folder would break something, so its own command is the only way.
    var commandOnly = false
    /// List every match as one row ("node_modules in 14 projects") instead of one row each.
    var groups = false
    /// The folder's own name is a bundle ID: the row is named after the app, and warns while it's running.
    var namedByBundleID = false
    /// A restart clears it. It's never moved to the Trash by hand.
    var restartClears = false
    /// macOS or a running system owns it, so it's never offered for the Trash.
    var notTrashable = false
    /// The app that owns this, when it isn't in the folder's own name. It's named if it's running.
    var appBundleID: String? = nil
    /// The folder's own name says what this is ("Stray"), and the rule's title says what kind of thing that is.
    var usesFolderName = false
    /// A file that must be inside for this to be what its name suggests. "venv" is also a folder inside Python itself.
    var marker: String? = nil
    /// What it's rebuilt from: any of these next to it, with `*` for any ending. Without one, nothing says what to put back.
    var recipe: [String]? = nil
    /// For a folder of many tools' caches: the ones known to come back with no help. Anything else may be more than a cache.
    var knownNames: Set<String>? = nil
    /// Never one suggestion as a whole, because it holds more than its name says: the things in it are suggested one by one.
    var thingByThing = false
    /// Can come back, but nothing proves it, so the slider leaves it to you.
    var askFirst = false
    /// Where it's listed in Free Up.
    var box: BoxKind = .other
}

/// A fixed set of names the scanner can ask about from any thread, with no String and no reference counting.
struct NameTable {
    private static let slots = 128
    private let keys: UnsafeMutablePointer<UInt64>

    init(_ names: [String]) {
        keys = .allocate(capacity: Self.slots)
        keys.initialize(repeating: 0, count: Self.slots)
        for name in names {
            let h = RuleBook.hash(name)
            var slot = Int(truncatingIfNeeded: h >> 7) & (Self.slots - 1)
            while keys[slot] != 0 { slot = (slot + 1) & (Self.slots - 1) }
            keys[slot] = h
        }
    }

    @inline(__always) func contains(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        let h = RuleBook.hash(p, n)
        var slot = Int(truncatingIfNeeded: h >> 7) & (Self.slots - 1)
        while keys[slot] != 0 {
            if keys[slot] == h { return true }
            slot = (slot + 1) & (Self.slots - 1)
        }
        return false
    }
}

/// Everything Headroom knows about particular folders, and the tables the scanner uses to look that up quickly.
final class RuleBook: @unchecked Sendable {
    static let swap = Rule(title: "Memory swap", detail: "Memory that macOS moved to disk. It fills up when many apps are open and resets on restart.",
                           tier: .noLoss, kind: .system, restartClears: true, notTrashable: true)
    static let updates = Rule(title: "Startup and updates", detail: "The startup volumes, plus any downloaded macOS update. Installing a waiting update frees most of the extra space.",
                              tier: .noLoss, kind: .system, notTrashable: true)
    static let macOS = Rule(title: "macOS", detail: "The operating system, on its own sealed volume. It can't be changed or removed.",
                            tier: .handsOff, kind: .system, notTrashable: true)
    static let recovery = Rule(title: "Recovery", detail: "macOS Recovery, for repairing or reinstalling macOS.",
                               tier: .handsOff, kind: .system, notTrashable: true)
    static let hiddenData = Rule(title: "Hidden", detail: "In use, but Headroom can't read it: private macOS folders, root-only data and APFS snapshots.",
                                 tier: .handsOff, kind: .system, notTrashable: true)

    private(set) var rules: [Rule] = [Rule(title: "", detail: "", tier: .none)]
    /// Rule IDs up to this one only set a colour.
    private(set) var neutralLimit: UInt16 = 0
    private var forcedKinds: UnsafeMutablePointer<UInt8>
    private var ruleIDs: [String: UInt16] = [:]

    // Path rules: a small table of (state, folder name hash) → next state, plus a wildcard per state.
    private var transitionKeys: UnsafeMutablePointer<UInt64>
    private var transitionValues: UnsafeMutablePointer<UInt8>
    private var wildcard: UnsafeMutablePointer<UInt8>
    private var stateRule: UnsafeMutablePointer<UInt16>
    private static let transitionSlots = 4096
    private static let maxStates = 256
    /// Room for this many rules. A test checks they fit.
    static let ruleSlots = 512

    // Rules that apply anywhere a folder has this name.
    private var nameKeys: UnsafeMutablePointer<UInt64>
    private var nameRules: UnsafeMutablePointer<UInt16>
    private static let nameSlots = 512

    private var stateCount = 1

    // Folder extensions that make a folder one thing to the Finder. What's inside isn't yours to pick apart.
    private let packages = NameTable(["app", "appex", "bundle", "framework", "kext", "xcframework", "plugin", "pkg",
                                      "photoslibrary", "aplibrary", "fcpbundle", "imovielibrary", "tvlibrary", "musiclibrary",
                                      "logicx", "band", "xcarchive", "sparsebundle", "dtbase2", "lrlibrary", "rtfd"])
    // Folders that are nearly all tiny files: about half the reading on a typical disk, for under a tenth of the bytes.
    private let slowFolders = NameTable(["node_modules", ".venv", "venv", "__pycache__", "site-packages", ".git", "Pods", ".build",
                                         "DerivedData", ".gradle", ".cargo", ".npm", ".pnpm", "Caches", ".cache"])

    private(set) var swapRule: UInt16 = 0
    private(set) var updatesRule: UInt16 = 0
    private(set) var macOSRule: UInt16 = 0
    private(set) var recoveryRule: UInt16 = 0
    private(set) var hiddenRule: UInt16 = 0

    init(homePath: String) {
        transitionKeys = .allocate(capacity: Self.transitionSlots)
        transitionValues = .allocate(capacity: Self.transitionSlots)
        wildcard = .allocate(capacity: Self.maxStates)
        stateRule = .allocate(capacity: Self.maxStates)
        nameKeys = .allocate(capacity: Self.nameSlots)
        nameRules = .allocate(capacity: Self.nameSlots)
        forcedKinds = .allocate(capacity: Self.ruleSlots)
        forcedKinds.initialize(repeating: 255, count: Self.ruleSlots)
        transitionKeys.initialize(repeating: 0, count: Self.transitionSlots)
        transitionValues.initialize(repeating: 0, count: Self.transitionSlots)
        wildcard.initialize(repeating: 0, count: Self.maxStates)
        stateRule.initialize(repeating: 0, count: Self.maxStates)
        nameKeys.initialize(repeating: 0, count: Self.nameSlots)
        nameRules.initialize(repeating: 0, count: Self.nameSlots)

        for (pattern, rule) in Self.neutralRules { insert(pattern.split(separator: "/").map(String.init), rule: add(rule)) }
        neutralLimit = UInt16(rules.count - 1)

        swapRule = add(Self.swap)
        updatesRule = add(Self.updates)
        macOSRule = add(Self.macOS)
        recoveryRule = add(Self.recovery)
        hiddenRule = add(Self.hiddenData)

        let home = homePath.split(separator: "/").map(String.init)
        for (pattern, rule) in Self.pathRules {
            var parts = pattern.split(separator: "/").map(String.init)
            if parts.first == "~" { parts.replaceSubrange(0...0, with: home) }
            insert(parts, rule: add(rule))
        }
        for (name, rule) in Self.nameRuleList {
            insertName(name, rule: add(rule))
        }
        fingerprint = Self.fingerprint(of: rules, states: stateCount, neutral: neutralLimit)
    }

    /// What the numbers in a saved map mean: these rules in this order, the path table they fill, and how a node is laid
    /// out. A map saved under another fingerprint isn't shown, because its numbers would name the wrong rules, or ones past
    /// the last.
    private(set) var fingerprint: UInt64 = 0

    private static func fingerprint(of rules: [Rule], states: Int, neutral: UInt16) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ text: String) {
            for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
            hash = (hash ^ 0xFF) &* 0x0000_0100_0000_01B3
        }
        for rule in rules { mix(rule.title); mix(rule.detail); mix("\(rule.tier) \(rule.kind?.rawValue ?? 255)") }
        mix("\(states) \(neutral) \(Kind.count) \(MemoryLayout<Node>.stride) \(DiskTree.statStride)")
        return hash
    }

    deinit {
        transitionKeys.deallocate(); transitionValues.deallocate(); wildcard.deallocate(); stateRule.deallocate()
        nameKeys.deallocate(); nameRules.deallocate(); forcedKinds.deallocate()
    }

    /// The kind every file under this rule counts as, read without touching any reference counts.
    @inline(__always) func forcedKind(_ id: UInt16) -> UInt8? {
        guard Int(id) < Self.ruleSlots else { return nil }
        let k = forcedKinds[Int(id)]
        return k == 255 ? nil : k
    }

    /// A number past the last rule, which only a damaged saved map could hold, counts as no rule.
    func rule(_ id: UInt16) -> Rule { Int(id) < rules.count ? rules[Int(id)] : rules[0] }

    /// The rule that applies anywhere a folder has this name.
    func ruleID(titled title: String) -> UInt16? {
        rules.firstIndex { $0.title == title }.map(UInt16.init)
    }

    func ruleID(forName name: String) -> UInt16 {
        let bytes = Array(name.utf8)
        return bytes.withUnsafeBufferPointer { ruleForName($0.baseAddress!, $0.count) }
    }

    private func add(_ rule: Rule) -> UInt16 {
        // The same words can name two rules: Xcode's own build folder, and one in a project, which is grouped with the others.
        let key = rule.title + "\u{1}" + rule.detail + "\u{1}\(rule.groups)\u{1}\(rule.box.rawValue)"
        if let id = ruleIDs[key] { return id }
        rules.append(rule)
        let id = UInt16(rules.count - 1)
        ruleIDs[key] = id
        if let kind = rule.kind, Int(id) < Self.ruleSlots { forcedKinds[Int(id)] = kind.rawValue }
        return id
    }

    private func insert(_ parts: [String], rule: UInt16) {
        var state = 0
        for part in parts {
            if part == "*" {
                if wildcard[state] == 0 { wildcard[state] = newState() }
                state = Int(wildcard[state])
            } else {
                let key = Self.key(state: state, hash: Self.hash(part))
                var slot = Int(truncatingIfNeeded: key &* 0x9E37_79B9_7F4A_7C15 >> 40) & (Self.transitionSlots - 1)
                var found = false
                while transitionKeys[slot] != 0 {
                    if transitionKeys[slot] == key { state = Int(transitionValues[slot]); found = true; break }
                    slot = (slot + 1) & (Self.transitionSlots - 1)
                }
                if !found {
                    let next = newState()
                    transitionKeys[slot] = key
                    transitionValues[slot] = next
                    state = Int(next)
                }
            }
        }
        stateRule[state] = rule
    }

    private func newState() -> UInt8 {
        precondition(stateCount < Self.maxStates - 1)
        stateCount += 1
        return UInt8(stateCount - 1)
    }

    private func insertName(_ name: String, rule: UInt16) {
        let h = Self.hash(name)
        var slot = Int(truncatingIfNeeded: h >> 7) & (Self.nameSlots - 1)
        while nameKeys[slot] != 0 { slot = (slot + 1) & (Self.nameSlots - 1) }
        nameKeys[slot] = h
        nameRules[slot] = rule
    }

    private static func key(state: Int, hash: UInt64) -> UInt64 { (hash << 8 | UInt64(state)) | 1 << 63 }

    static func hash(_ s: String) -> UInt64 {
        let bytes = Array(s.utf8)
        return bytes.withUnsafeBufferPointer { $0.isEmpty ? 1 : hash($0.baseAddress!, $0.count) }
    }

    @inline(__always) static func hash(_ p: UnsafePointer<UInt8>, _ n: Int) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for i in 0..<n { h = (h ^ UInt64(p[i])) &* 0x0000_0100_0000_01B3 }
        return h | 1
    }

    /// Follows the path table one folder down. Returns the next state and the rule found there, if any.
    @inline(__always) func step(state: UInt8, name: UnsafePointer<UInt8>, length: Int) -> (state: UInt8, rule: UInt16) {
        if state == 0 && !isRootStep { return (0, 0) }
        let key = Self.key(state: Int(state), hash: Self.hash(name, length))
        var slot = Int(truncatingIfNeeded: key &* 0x9E37_79B9_7F4A_7C15 >> 40) & (Self.transitionSlots - 1)
        while transitionKeys[slot] != 0 {
            if transitionKeys[slot] == key {
                let next = transitionValues[slot]
                return (next, stateRule[Int(next)])
            }
            slot = (slot + 1) & (Self.transitionSlots - 1)
        }
        let wild = wildcard[Int(state)]
        return wild == 0 ? (0, 0) : (wild, stateRule[Int(wild)])
    }

    /// State 0 is both the root and "no match", so only the very top of the scan may step from it.
    var isRootStep = false

    func stepFromRoot(_ name: String) -> (state: UInt8, rule: UInt16) {
        let bytes = Array(name.utf8)
        isRootStep = true
        defer { isRootStep = false }
        return bytes.withUnsafeBufferPointer { step(state: 0, name: $0.baseAddress!, length: $0.count) }
    }

    @inline(__always) func ruleForName(_ p: UnsafePointer<UInt8>, _ n: Int) -> UInt16 {
        if n < 3 || n > 24 { return 0 }
        let h = Self.hash(p, n)
        var slot = Int(truncatingIfNeeded: h >> 7) & (Self.nameSlots - 1)
        while nameKeys[slot] != 0 {
            if nameKeys[slot] == h { return nameRules[slot] }
            slot = (slot + 1) & (Self.nameSlots - 1)
        }
        return 0
    }

    /// Whether this folder name makes it a package, such as an app or a Photos library.
    @inline(__always) func isPackage(_ name: UnsafePointer<UInt8>, _ length: Int) -> Bool {
        var i = length - 1
        let stop = max(0, length - 16)
        while i > stop {
            if name[i] == 0x2E { return packages.contains(name + i + 1, length - i - 1) }
            i -= 1
        }
        return false
    }

    @inline(__always) func isSlowFolder(_ name: UnsafePointer<UInt8>, _ length: Int) -> Bool {
        length <= 16 && slowFolders.contains(name, length)
    }

    // MARK: What Headroom knows

    private static func cache(_ title: String, _ detail: String, command: String? = nil) -> Rule {
        Rule(title: title, detail: detail, tier: .rebuilds, kind: .cache, command: command, box: .developer)
    }
    private static func build(_ title: String, _ detail: String, command: String? = nil) -> Rule {
        Rule(title: title, detail: detail, tier: .rebuilds, kind: .cache, command: command, groups: true, box: .developer)
    }
    private static func only(_ rule: Rule) -> Rule {
        var copy = rule
        copy.commandOnly = true
        return copy
    }
    private static func marked(_ rule: Rule, _ marker: String) -> Rule {
        var copy = rule
        copy.marker = marker
        return copy
    }
    /// A model cache also holds your login, so it's only ever suggested model by model.
    private static var huggingFace: Rule {
        var rule = model("Hugging Face models", "AI model weights. Each is re-downloaded on next use.")
        rule.thingByThing = true
        return rule
    }
    private static func rebuilt(from recipe: [String], _ rule: Rule) -> Rule {
        var copy = rule
        copy.recipe = recipe
        return copy
    }
    private static let pythonRecipes = ["requirements*", "pyproject.toml", "setup.py", "setup.cfg", "Pipfile", "uv.lock", "poetry.lock", "environment.yml", "environment.yaml"]
    /// In `~/.cache`, these are known to come back by themselves, with nothing lost.
    private static let knownToolCaches: Set<String> = [
        "pip", "pipx", "pypoetry", "pre-commit", "ruff", "mypy", "black", "pylint", "bazel", "ccache", "sccache", "clang", "clangd", "go-build",
        "golangci-lint", "yarn", "pnpm", "npm", "node-gyp", "electron", "electron-builder", "puppeteer", "playwright", "ms-playwright", "selenium",
        "matplotlib", "fontconfig", "thumbnails", "mesa_shader_cache", "Homebrew", "gstreamer-1.0", "typescript", "starship", "gh", "yt-dlp", "cycles",
    ]
    private static func model(_ title: String, _ detail: String) -> Rule {
        Rule(title: title, detail: detail, tier: .redownload, kind: .model, box: .models)
    }
    private static func owned(_ rule: Rule, _ bundleID: String) -> Rule {
        var copy = rule
        copy.appBundleID = bundleID
        // An app's own cache, not a developer tool's.
        copy.box = .caches
        return copy
    }
    private static func named(_ rule: Rule) -> Rule {
        var copy = rule
        copy.usesFolderName = true
        return copy
    }

    /// Whole areas with one colour. They say nothing about removing anything.
    static let neutralRules: [(String, Rule)] = [
        ("Applications", Rule(title: "Apps", detail: "Installed apps. Deleting one leaves its settings behind.", tier: .none, kind: .app)),
        ("Library", Rule(title: "System Library", detail: "Files shared by every user and by the system.", tier: .none, kind: .system)),
        ("System", Rule(title: "System", detail: "The parts of macOS that live on your data volume.", tier: .none, kind: .system)),
        ("private", Rule(title: "System data", detail: "Logs, temporary files and the working data of macOS.", tier: .none, kind: .system)),
        ("usr", Rule(title: "System tools", detail: "Command-line tools.", tier: .none, kind: .code)),
        ("opt", Rule(title: "Installed tools", detail: "Command-line tools, usually from Homebrew.", tier: .none, kind: .code)),
    ]

    /// `~` is your home folder, and `*` is any one folder. The most specific match wins, because it's reached later.
    static let pathRules: [(String, Rule)] = [
        ("~/.Trash", Rule(title: "Trash", detail: "Deleted items. They use space until the Trash is emptied.", tier: .noLoss, notTrashable: true, box: .trash)),

        ("private/tmp", Rule(title: "Temporary files", detail: "Scratch files from running apps and sessions. A restart clears them.", tier: .noLoss, kind: .cache, restartClears: true, notTrashable: true)),
        ("private/var/folders/*/*/X/com.google.Chrome.code_sign_clone", Rule(title: "Chrome signing copies", detail: "Copies Chrome makes of itself to check its signature. Mostly clones of Chrome. A restart clears them.", tier: .noLoss, kind: .cache, restartClears: true, notTrashable: true)),
        ("System/Library/AssetsV2", Rule(title: "System downloads", detail: "Siri voices, Apple Intelligence models and other things macOS fetches for itself. macOS manages them.", tier: .handsOff, kind: .system, notTrashable: true)),
        ("Library/Caches/*", Rule(title: "System cache", detail: "Cached files shared by every user. They rebuild themselves.", tier: .rebuilds, kind: .cache, box: .caches)),

        ("~/Library/Caches/*", Rule(title: "App cache", detail: "An app's cache. Rebuilt as you use the app, which may be slower at first.", tier: .rebuilds, kind: .cache, namedByBundleID: true, box: .caches)),
        ("~/Library/Logs", Rule(title: "Logs", detail: "Log files and crash reports. Apps write new ones.", tier: .rebuilds, kind: .cache, box: .junk)),
        ("~/Library/Caches/Homebrew", cache("Homebrew downloads", "Installers Homebrew kept after installing.", command: "brew cleanup -s")),
        ("~/Library/Caches/pip", cache("pip downloads", "Python packages pip kept after installing.", command: "pip cache purge")),
        ("~/Library/Caches/Google", Rule(title: "Chrome cache", detail: "Copies of web pages. Sites load a little slower at first. Your logins aren't stored here.", tier: .rebuilds, kind: .cache, appBundleID: "com.google.Chrome", box: .caches)),
        ("~/Library/Caches/ms-playwright", cache("Playwright browsers", "Browsers Playwright downloads for testing.", command: "npx playwright uninstall --all")),
        ("~/.cache/*", { var rule = named(cache("Tool cache", "A command-line tool's cache. It rebuilds the next time the tool runs.")); rule.knownNames = knownToolCaches; return rule }()),
        ("~/.cache/uv", only(cache("uv cache", "Python packages cached by uv. Quit tools using them first.", command: "uv cache prune"))),
        ("~/.cache/huggingface", huggingFace),
        ("~/.npm/_cacache", cache("npm cache", "Packages npm has downloaded before.", command: "npm cache clean --force")),
        ("~/.npm/_npx", cache("npx cache", "Tools npx has downloaded before.")),
        ("~/.gradle/caches", cache("Gradle cache", "Android and Java build dependencies. The next build downloads them again and takes longer.")),
        ("~/.gradle/wrapper/dists", cache("Gradle versions", "Copies of Gradle itself, downloaded by project builds.")),
        ("~/.cargo/registry", cache("Cargo packages", "Rust dependencies. The next build downloads them again.")),
        ("~/go/pkg/mod", only(cache("Go modules", "Go dependencies. The next build downloads them again.", command: "go clean -modcache"))),
        ("~/Library/pnpm/store", only(cache("pnpm store", "Packages shared between your projects.", command: "pnpm store prune"))),
        ("~/.pnpm-store", only(cache("pnpm store", "Packages shared between your projects.", command: "pnpm store prune"))),
        ("~/.bun/install/cache", cache("Bun cache", "Packages Bun has downloaded before.", command: "bun pm cache rm")),
        ("~/Library/Developer/Xcode/DerivedData", cache("Xcode build output", "Xcode makes this again on the next build, which takes longer.")),
        ("~/Library/Developer/CoreSimulator/Caches", cache("Simulator caches", "Rebuild the next time a simulator starts.")),
        ("~/Library/Application Support/Claude/Cache", owned(cache("Claude app cache", "Web content cached by the Claude app."), "com.anthropic.claudefordesktop")),
        ("~/Library/Application Support/Claude/Code Cache", owned(cache("Claude app code cache", "Compiled code cached by the Claude app."), "com.anthropic.claudefordesktop")),
        ("~/Library/Application Support/Code/Cache", owned(cache("VS Code cache", "Web content cached by VS Code."), "com.microsoft.VSCode")),
        ("~/Library/Application Support/Code/CachedData", owned(cache("VS Code compiled cache", "Compiled code cached by VS Code."), "com.microsoft.VSCode")),

        ("~/Library/Developer/Xcode/iOS DeviceSupport", Rule(title: "iPhone debug symbols", detail: "Xcode copies these from each iPhone or iOS version you've debugged. It copies them again when needed.", tier: .redownload, kind: .cache, box: .developer)),
        ("~/Library/Developer/CoreSimulator/Devices", Rule(title: "Simulator devices", detail: "Simulated iPhones and their data. Apps and files inside them are lost.", tier: .redownload, kind: .app, command: "xcrun simctl delete unavailable", commandOnly: true, box: .developer)),
        ("~/Library/Application Support/Steam/steamapps/common/*", named(Rule(title: "Steam game", detail: "Steam can download this game again. Check first that your saves are in Steam Cloud.", tier: .redownload, kind: .app, box: .games))),
        ("~/.ollama/models", model("Ollama models", "AI model weights. Pull them again with Ollama.")),
        ("~/.lmstudio/models", model("LM Studio models", "AI model weights. Download them again from LM Studio.")),
        ("~/LLM/*", { var rule = named(model("Local AI models", "AI model weights. Re-downloadable if you know where they came from.")); rule.askFirst = true; return rule }()),
        ("~/LLM/huggingface", huggingFace),
        ("~/Library/Android/sdk/system-images", Rule(title: "Android system images", detail: "Emulator system images. Android Studio re-downloads them when needed.", tier: .redownload, kind: .app, box: .developer)),
        ("~/Library/Android/sdk/ndk/*", named(Rule(title: "Android NDK", detail: "A version of the native build tools. A project that asks for it downloads it again.", tier: .redownload, kind: .app, box: .developer))),
        ("~/.rustup/toolchains", Rule(title: "Rust toolchains", detail: "Versions of the Rust compiler. rustup installs them again.", tier: .redownload, kind: .app, box: .developer)),
        ("~/Library/Application Support/com.apple.wallpaper", Rule(title: "Aerial wallpapers", detail: "Video wallpapers. macOS downloads them again when you pick one.", tier: .redownload, kind: .video, notTrashable: true)),

        ("~/.android/avd/*", named(Rule(title: "Android emulator", detail: "A virtual Android device and everything on it. Removing it loses that data.", tier: .yourCall, kind: .app, box: .developer))),
        ("~/Library/Developer/Xcode/Archives", Rule(title: "Xcode archives", detail: "Past app builds, only needed to debug crashes in those versions.", tier: .yourCall, kind: .app, box: .developer)),
        ("~/Library/Application Support/MobileSync/Backup", Rule(title: "iPhone backups", detail: "Local backups of your iPhone or iPad. They can't be recreated if the device is gone.", tier: .yourCall, kind: .archive, box: .backups)),
        ("~/Library/Containers/com.docker.docker", Rule(title: "Docker", detail: "Docker's images and volumes. Prune inside Docker: moving this folder removes everything at once.", tier: .yourCall, kind: .app, command: "docker system prune", commandOnly: true, notTrashable: true, box: .developer)),
    ]

    static let nameRuleList: [(String, Rule)] = [
        ("node_modules", rebuilt(from: ["package.json"], build("node_modules", "JavaScript packages for a project. `npm install` brings them back."))),
        (".venv", rebuilt(from: pythonRecipes, marked(build("Python environments", "A project's Python packages. Recreate them with its requirements or `uv sync`."), "pyvenv.cfg"))),
        ("venv", rebuilt(from: pythonRecipes, marked(build("Python environments", "A project's Python packages. Recreate them with its requirements or `uv sync`."), "pyvenv.cfg"))),
        ("__pycache__", build("Python bytecode", "Compiled Python. It's made again the next time the code runs.")),
        (".pytest_cache", build("Python tool caches", "Caches from Python tools. They rebuild on the next run.")),
        (".mypy_cache", build("Python tool caches", "Caches from Python tools. They rebuild on the next run.")),
        (".ruff_cache", build("Python tool caches", "Caches from Python tools. They rebuild on the next run.")),
        (".build", rebuilt(from: ["Package.swift"], build("Swift build output", "SwiftPM makes this again on the next build."))),
        ("DerivedData", build("Xcode build output", "Xcode makes this again on the next build, which takes longer.")),
        (".gradle", build("Gradle project caches", "Gradle makes these again on the next build.")),
        ("Pods", rebuilt(from: ["Podfile"], marked(build("CocoaPods packages", "`pod install` brings these back."), "Manifest.lock"))),
        (".next", rebuilt(from: ["package.json"], build("Web build output", "The framework makes this again on the next build."))),
        (".nuxt", rebuilt(from: ["package.json"], build("Web build output", "The framework makes this again on the next build."))),
        (".turbo", rebuilt(from: ["package.json"], build("Web build output", "The framework makes this again on the next build."))),
        (".parcel-cache", rebuilt(from: ["package.json"], build("Web build output", "The framework makes this again on the next build."))),
        (".dart_tool", rebuilt(from: ["pubspec.yaml"], build("Flutter build output", "`flutter pub get` and the next build make this again."))),
        (".terraform", build("Terraform plugins", "`terraform init` brings these back.")),
        (".tox", rebuilt(from: ["tox.ini", "pyproject.toml", "setup.cfg"], build("Python test environments", "tox makes these again on the next run."))),
        ("huggingface", huggingFace),
    ]

    /// Folders macOS guards. Touching one without permission brings up a prompt, so these wait for Full Disk Access.
    static let guardedInHome: Set<String> = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", ".Trash"]
    static let guardedInLibrary: Set<String> = ["Containers", "Group Containers", "Mail", "Messages", "Safari", "Calendars", "Reminders",
                                                "Mobile Documents", "CloudStorage", "HomeKit", "IdentityServices", "Metadata", "Cookies",
                                                "Autosave Information", "Biome", "Suggestions", "Accounts", "PersonalizationPortrait",
                                                "DuetExpertCenter", "Shortcuts", "Weather", "Sharing", "Daemon Containers"]
}
