import Foundation

/// What a byte is. In the Map view, this is what colour means.
enum Kind: UInt8, CaseIterable {
    case other = 0, video, audio, image, document, code, app, archive, model, cache, system

    static let count = Kind.allCases.count

    var title: String {
        switch self {
        case .other: "Other"
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Images"
        case .document: "Documents"
        case .code: "Code"
        case .app: "Apps"
        case .archive: "Archives"
        case .model: "AI models"
        case .cache: "Caches"
        case .system: "System"
        }
    }
}

/// Maps a file name to a Kind without creating a String: the last extension, lowercased, packed into a UInt64.
struct ExtensionTable {
    static let shared = ExtensionTable()
    private static let slots = 2048
    private let keys: UnsafeMutablePointer<UInt64>
    private let values: UnsafeMutablePointer<UInt8>

    private init() {
        keys = .allocate(capacity: Self.slots)
        values = .allocate(capacity: Self.slots)
        keys.initialize(repeating: 0, count: Self.slots)
        values.initialize(repeating: 0, count: Self.slots)
        let groups: [(Kind, String)] = [
            (.video, "mp4 mov mkv m4v avi webm mpg mpeg m2ts wmv flv prores mxf vob 3gp hevc"),
            (.audio, "mp3 wav aiff aif flac m4a aac ogg opus caf alac wma mid midi"),
            (.image, "jpg jpeg png gif heic heif webp tiff tif bmp raw cr2 cr3 nef arw dng psd ai svg exr hdr tga icns ico"),
            (.document, "pdf doc docx ppt pptx xls xlsx pages numbers key txt md rtf csv tsv epub mobi tex log jsonl ndjson parquet"),
            (.code, "swift c h cc cpp hpp m mm py js jsx ts tsx mjs cjs rs go java kt kts rb php html css scss json yaml yml toml xml sh zsh metal glsl wgsl sql lock map pyc o a class"),
            (.app, "dylib so dll framework app exe appex kext bundle wasm jar aab apk ipa pak asar car nib"),
            (.archive, "zip tar gz tgz bz2 xz 7z rar dmg pkg iso img sparsebundle sparseimage qcow2 vdi vmdk zst"),
            (.model, "safetensors gguf ggml ckpt pt pth onnx mlmodel mlpackage mlmodelc tflite npz h5 pb"),
            (.cache, "cache tmp temp"),
            (.system, "plist db sqlite sqlite3 wal shm"),
        ]
        for (kind, list) in groups {
            for ext in list.split(separator: " ") {
                var key: UInt64 = 0
                for byte in ext.utf8 { key = key << 8 | UInt64(byte) }
                var slot = Self.hash(key)
                while keys[slot] != 0 { slot = (slot + 1) & (Self.slots - 1) }
                keys[slot] = key
                values[slot] = kind.rawValue
            }
        }
    }

    @inline(__always) private static func hash(_ key: UInt64) -> Int {
        Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> 53) & (slots - 1)
    }

    /// `name` is UTF-8 without the terminating zero.
    @inline(__always) func kind(name: UnsafePointer<UInt8>, length: Int) -> UInt8 {
        var i = length - 1
        let stop = max(0, length - 13)
        var key: UInt64 = 0
        var shift: UInt64 = 0
        while i >= stop {
            let c = name[i]
            if c == 0x2E {                                      // '.'
                if key == 0 || i == 0 { return 0 }
                var slot = Self.hash(key)
                while keys[slot] != 0 {
                    if keys[slot] == key { return values[slot] }
                    slot = (slot + 1) & (Self.slots - 1)
                }
                return 0
            }
            if shift >= 64 { return 0 }
            let lower = (c >= 0x41 && c <= 0x5A) ? c | 0x20 : c
            key |= UInt64(lower) << shift
            shift += 8
            i -= 1
        }
        return 0
    }
}
