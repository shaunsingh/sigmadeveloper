import Foundation
import SwiftUI
import UIKit

@MainActor
@Observable
final class LibraryStore {
    private(set) var items: [LibraryItem] = []
    var defaults = DevelopSettings()

    /// LRU capped numbnails
    private(set) var thumbnails: [UUID: UIImage] = [:]
    private(set) var isImporting = false
    private(set) var importProgress: (done: Int, total: Int)?
    private(set) var exportProgress: (done: Int, total: Int)?

    let engine = RenderEngine()
    /// Purely-internal bookkeeping; never read by a view, so kept out of observation.
    @ObservationIgnored private var thumbnailTasks: Set<UUID> = []
    /// Mirrors `items` ids for O(1) membership; kept in sync at every mutation below.
    @ObservationIgnored private var itemIDs: Set<UUID> = []
    /// LRU order for `thumbnails` (front = coldest), touched on cell appearance.
    @ObservationIgnored private var thumbnailLRU: [UUID] = []
    private static let thumbnailCap = 64

    init() {
        Paths.resetSession()
        // decode cache holds proxy but we can drop them for mem pressure
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [engine] _ in
            engine.releaseCache()
        }
    }

    // MARK: - Import

    func importPicked(_ urls: [URL]) async {
        isImporting = true
        defer { isImporting = false; importProgress = nil }

        let sources = await Self.expand(urls)
        guard !sources.isEmpty else { return }

        let defaults = self.defaults
        var inserted = 0
        for (i, src) in sources.enumerated() {
            importProgress = (i + 1, sources.count)
            guard let item = await Self.importOne(src, defaults: defaults) else { continue }
            // item stream
            items.insert(item, at: inserted)
            inserted += 1
            itemIDs.insert(item.id)
            ensureThumbnail(item)
        }
    }

    private nonisolated static func expand(_ urls: [URL]) async -> [URL] {
        var out: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            var isDir: ObjCBool = false
            guard Paths.fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let kids = (try? Paths.fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                out += kids.filter { RawKind.of(extension: $0.pathExtension) != nil }
            } else if RawKind.of(extension: url.pathExtension) != nil {
                out.append(url)
            }
        }
        return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private nonisolated static func importOne(_ src: URL, defaults: DevelopSettings) async -> LibraryItem? {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        let ext = src.pathExtension.lowercased()
        guard let kind = RawKind.of(extension: ext) else { return nil }
        let id = UUID()
        let storedName = "\(id.uuidString).\(ext)"
        let dest = Paths.originals.appendingPathComponent(storedName)
        do {
            try Paths.fm.copyItem(at: src, to: dest)
        } catch {
            // Fall back to a byte copy if the coordinated copy fails.
            guard let data = try? Data(contentsOf: src), (try? data.write(to: dest)) != nil else { return nil }
        }
        return LibraryItem(id: id, fileName: src.lastPathComponent, storedName: storedName,
                           kind: kind, importedAt: .now, settings: defaults)
    }

    // MARK: - Mutation

    func updateSettings(_ settings: DevelopSettings, for item: LibraryItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard items[i].settings != settings else { return }
        items[i].settings = settings
        items[i].isCustomized = true
    }

    func applyGlobalDefaults() {
        let key = defaults.globalKey
        for i in items.indices where !items[i].isCustomized {
            items[i].settings.globalKey = key
            if thumbnails[items[i].id] != nil {
                renderThumbnail(items[i])
            } else {
                // drop stale looks
                try? Paths.fm.removeItem(at: Paths.thumbnail(items[i].id))
            }
        }
    }

    func delete(_ item: LibraryItem) {
        items.removeAll { $0.id == item.id }
        itemIDs.remove(item.id)
        thumbnails[item.id] = nil
        thumbnailLRU.removeAll { $0 == item.id }
        try? Paths.fm.removeItem(at: item.url)
        try? Paths.fm.removeItem(at: Paths.thumbnail(item.id))
    }

    // MARK: - Export

    func export(_ item: LibraryItem, settings: DevelopSettings, as format: ExportFormat) async throws -> URL {
        let resolvedFormat = item.exportFormat(preferred: format)
        let outputURL = Paths.exportURL(stem: item.fileStem, fileExtension: resolvedFormat.fileExtension)
        return try await engine.export(url: item.url, settings: settings, format: resolvedFormat, to: outputURL)
    }

    func exportAll() async throws -> [URL] {
        let snapshot = items
        guard !snapshot.isEmpty else { return [] }

        exportProgress = (0, snapshot.count)
        defer { exportProgress = nil }

        let jobs = snapshot.map { item in
            let format = item.exportFormat(preferred: item.settings.exportFormat)
            return RenderEngine.ExportJob(
                url: item.url, settings: item.settings, format: format,
                outputURL: Paths.exportURL(stem: item.fileStem, fileExtension: format.fileExtension))
        }
        return try await engine.exportBatch(jobs) { [weak self] done, total in
            Task { @MainActor in
                guard let self, done >= (self.exportProgress?.done ?? 0) else { return }
                self.exportProgress = (done, total)
            }
        }
    }

    // MARK: - Thumbnails

    func ensureThumbnail(_ item: LibraryItem) {
        guard thumbnails[item.id] == nil else { touchThumbnail(item.id); return }
        guard !thumbnailTasks.contains(item.id) else { return }
        thumbnailTasks.insert(item.id)
        let id = item.id
        Task {
            defer { thumbnailTasks.remove(id) }
            // check session disk cache first
            if let cached = await Self.loadThumbnail(id) {
                if itemIDs.contains(id) { storeThumbnail(cached, for: id) }
                return
            }
            await renderThumbnailNow(item)
        }
    }

    func refreshThumbnail(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        renderThumbnail(item)
    }

    func adoptThumbnail(from preview: UIImage, for id: UUID) {
        guard itemIDs.contains(id), let cgImage = preview.cgImage else { return }
        let source = RenderedImage(cgImage: cgImage)
        Task {
            let thumbnail = await engine.downscale(source, maxDimension: 700)
            guard itemIDs.contains(id) else { return }
            let image = UIImage(cgImage: thumbnail.cgImage)
            storeThumbnail(image, for: id)
            Self.persistThumbnail(image, for: id)
        }
    }

    private func renderThumbnail(_ item: LibraryItem) {
        guard !thumbnailTasks.contains(item.id) else { return }
        thumbnailTasks.insert(item.id)
        Task {
            defer { thumbnailTasks.remove(item.id) }
            await renderThumbnailNow(item)
        }
    }

    private func renderThumbnailNow(_ item: LibraryItem) async {
        let rendered = try? await engine.thumbnail(url: item.url, settings: item.settings, maxDimension: 700)
        guard itemIDs.contains(item.id), let cg = rendered?.cgImage else { return }
        let image = UIImage(cgImage: cg)
        storeThumbnail(image, for: item.id)
        Self.persistThumbnail(image, for: item.id)
    }

    private func storeThumbnail(_ image: UIImage, for id: UUID) {
        thumbnails[id] = image
        touchThumbnail(id)
        while thumbnails.count > Self.thumbnailCap, let coldest = thumbnailLRU.first {
            thumbnailLRU.removeFirst()
            thumbnails[coldest] = nil
        }
    }

    nonisolated private static func persistThumbnail(_ image: UIImage, for id: UUID) {
        Task.detached(priority: .utility) {
            guard let data = image.jpegData(compressionQuality: 0.85) else { return }
            try? data.write(to: Paths.thumbnail(id), options: .atomic)
        }
    }

    nonisolated private static func loadThumbnail(_ id: UUID) async -> UIImage? {
        let path = Paths.thumbnail(id).path
        return await Task.detached(priority: .utility) {
            // Decode off-main so the first draw doesn't pay it.
            UIImage(contentsOfFile: path)?.preparingForDisplay()
        }.value
    }

    private func touchThumbnail(_ id: UUID) {
        if let i = thumbnailLRU.firstIndex(of: id) { thumbnailLRU.remove(at: i) }
        thumbnailLRU.append(id)
    }
}
