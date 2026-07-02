import Foundation

enum Paths {
    static let fm = FileManager.default

    static var sessionRoot: URL {
        fm.temporaryDirectory.appendingPathComponent("SigmaDevelopSession", isDirectory: true)
    }
    static var originals: URL { sessionRoot.appendingPathComponent("Originals", isDirectory: true) }
    static var exports: URL { sessionRoot.appendingPathComponent("Exports", isDirectory: true) }
    static var thumbnails: URL { sessionRoot.appendingPathComponent("Thumbnails", isDirectory: true) }

    static func thumbnail(_ id: UUID) -> URL {
        thumbnails.appendingPathComponent("\(id.uuidString).jpg")
    }

    private static var legacyDocuments: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private static var legacyCaches: URL { fm.urls(for: .cachesDirectory, in: .userDomainMask)[0] }

    static func resetSession() {
        try? fm.removeItem(at: sessionRoot)
        try? fm.removeItem(at: legacyDocuments.appendingPathComponent("Originals", isDirectory: true))
        try? fm.removeItem(at: legacyDocuments.appendingPathComponent("library.json"))
        try? fm.removeItem(at: legacyCaches.appendingPathComponent("Thumbnails", isDirectory: true))
        ensureDirectories()
    }

    static func ensureDirectories() {
        try? fm.createDirectory(at: originals, withIntermediateDirectories: true)
        try? fm.createDirectory(at: exports, withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbnails, withIntermediateDirectories: true)
    }

    static func exportURL(stem: String, fileExtension: String) -> URL {
        ensureDirectories()
        let token = UUID().uuidString.prefix(8).lowercased()
        return exports.appendingPathComponent("\(stem)-\(token).\(fileExtension)")
    }
}

enum RawKind: String, Codable, Sendable {
    case x3f
    case raw
    case image

    static let extensions: [String: RawKind] = {
        var map: [String: RawKind] = ["x3f": .x3f]
        for e in ["dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "sr2", "srf",
                  "raf", "rw2", "orf", "pef", "raw", "rwl", "dcr", "kdc", "mrw", "3fr", "fff"] {
            map[e] = .raw
        }
        for e in ["tif", "tiff", "jpg", "jpeg", "png", "heic", "heif"] { map[e] = .image }
        return map
    }()

    static func of(extension ext: String) -> RawKind? { extensions[ext.lowercased()] }
}

struct LibraryItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var fileName: String
    var storedName: String
    var kind: RawKind
    var importedAt: Date
    var settings: DevelopSettings
    var isCustomized: Bool = false

    var isX3F: Bool { kind == .x3f }
    var url: URL { Paths.originals.appendingPathComponent(storedName) }
    var fileStem: String {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        return stem.isEmpty ? id.uuidString : stem
    }

    var availableFormats: [ExportFormat] {
        isX3F ? ExportFormat.allCases : ExportFormat.allCases.filter { !$0.requiresX3F }
    }

    func exportFormat(preferred: ExportFormat) -> ExportFormat {
        availableFormats.contains(preferred) ? preferred : .heic
    }

    static func == (lhs: LibraryItem, rhs: LibraryItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
