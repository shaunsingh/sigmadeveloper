import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Darwin
#if os(iOS)
import UIKit
#endif

/// Serial disk publication without tying a queue singleton to the
/// `@MainActor` store type. `RenderedImage` safely carries immutable CGImage.
private actor ThumbnailCacheWriter {
    static let shared = ThumbnailCacheWriter()
    private var revisions: [UUID: UInt64] = [:]

    func write(_ rendered: RenderedImage, for id: UUID, revision: UInt64) {
        guard revision >= (revisions[id] ?? 0) else { return }
        revisions[id] = revision
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, rendered.cgImage, [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        try? (data as Data).write(to: Paths.thumbnail(id), options: .atomic)
    }
}

@MainActor
@Observable
final class LibraryStore {
    private(set) var items: [LibraryItem] = []
    var defaults = DevelopSettings()

    /// LRU capped thumbnails. `CGImage` end to end — the engine's native
    /// currency on every platform, so the model never touches UIKit/AppKit.
    private(set) var thumbnails: [UUID: CGImage] = [:]
    private(set) var isImporting = false
    private(set) var importProgress: (done: Int, total: Int)?
    private(set) var exportProgress: (done: Int, total: Int)?
    private(set) var activeEditorIDs: Set<UUID> = []

    let engine = RenderEngine()
    /// Purely-internal bookkeeping; never read by a view, so kept out of observation.
    @ObservationIgnored private var thumbnailTasks: Set<UUID> = []
    /// Every thumbnail producer validates this revision before publishing.
    @ObservationIgnored private var thumbnailRevisions: [UUID: UInt64] = [:]
    @ObservationIgnored private var exportGeneration: UInt64 = 0
    /// Mirrors `items` ids for O(1) membership; kept in sync at every mutation below.
    @ObservationIgnored private var itemIDs: Set<UUID> = []
    /// LRU order for `thumbnails` (front = coldest), touched on cell appearance.
    @ObservationIgnored private var thumbnailLRU: [UUID] = []
    private static let thumbnailCap = 64

    init() {
        Paths.resetSession()
        #if os(iOS)
        // decode cache holds proxy but we can drop them for mem pressure
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [engine] _ in
            engine.releaseAll()
        }
        #endif
    }

    // MARK: - Import

    func importPicked(_ urls: [URL]) async {
        guard !isImporting else { return }
        isImporting = true
        engine.setThumbnailWorkSuspended(true)
        defer {
            engine.setThumbnailWorkSuspended(false)
            isImporting = false
            importProgress = nil
        }

        // Hold the security scope on every picked root for the whole batch:
        // children of a picked folder are readable only under the folder's
        // scope, so it must outlive their copies — not just the listing.
        let scopedRoots = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scopedRoots.forEach { $0.stopAccessingSecurityScopedResource() } }

        let sources = await Self.expand(urls)
        guard !sources.isEmpty else { return }

        let defaults = self.defaults
        let total = sources.count
        // Bounded parallel copies — sequential is fine on phone flash; macOS +
        // large RAWs are dog-slow one-by-one. Thumbnails stay async.
        let workers = min(total, 4)
        var done = 0
        var cursor = 0
        var inFlight = 0
        // Batch lands at the front in source (name-sorted) order even though
        // copies finish out of order.
        var placedSourceIndices: [Int] = []

        await withTaskGroup(of: (Int, LibraryItem?).self) { group in
            func spawn() {
                while inFlight < workers, cursor < sources.count {
                    let (index, src) = (cursor, sources[cursor])
                    cursor += 1
                    inFlight += 1
                    group.addTask { (index, await Self.importOne(src, defaults: defaults)) }
                }
            }
            spawn()
            for await (index, item) in group {
                inFlight -= 1
                done += 1
                importProgress = (done, total)
                if let item {
                    let position = placedSourceIndices.firstIndex { $0 > index }
                        ?? placedSourceIndices.count
                    placedSourceIndices.insert(index, at: position)
                    items.insert(item, at: position)
                    itemIDs.insert(item.id)
                }
                spawn()
            }
        }
    }

    private nonisolated static func expand(_ urls: [URL]) async -> [URL] {
        var out: [URL] = []
        for url in urls {
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
        let ext = src.pathExtension.lowercased()
        guard let kind = RawKind.of(extension: ext) else { return nil }
        let id = UUID()
        let storedName = "\(id.uuidString).\(ext)"
        let dest = Paths.originals.appendingPathComponent(storedName)
        // A session library does not need a physical duplicate on APFS.
        // `clonefile` creates an independent copy-on-write file in constant
        // time; file-provider/cross-volume sources fall back transparently.
        let cloned = src.withUnsafeFileSystemRepresentation { sourcePath in
            dest.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return false }
                return clonefile(sourcePath, destinationPath, 0) == 0
            }
        }
        if !cloned {
            try? Paths.fm.removeItem(at: dest)
        }
        do {
            if !cloned { try Paths.fm.copyItem(at: src, to: dest) }
        } catch {
            try? Paths.fm.removeItem(at: dest)
            // Last resort for providers that reject a coordinated file copy.
            guard let data = try? Data(contentsOf: src, options: .mappedIfSafe),
                  (try? data.write(to: dest)) != nil else { return nil }
        }
        guard Paths.fm.fileExists(atPath: dest.path) else {
            return nil
        }
        return LibraryItem(id: id, fileName: src.lastPathComponent, storedName: storedName,
                           kind: kind, importedAt: .now, settings: defaults)
    }

    // MARK: - Mutation

    /// One writable editor per library item. Separate photos remain fully
    /// independent across windows, while duplicate opens cannot overwrite a
    /// newer adjustment snapshot on close.
    func beginEditing(_ id: UUID) -> Bool {
        guard itemIDs.contains(id), !activeEditorIDs.contains(id) else { return false }
        activeEditorIDs.insert(id)
        return true
    }

    func endEditing(_ id: UUID) {
        activeEditorIDs.remove(id)
    }

    func isBeingEdited(_ id: UUID) -> Bool {
        activeEditorIDs.contains(id)
    }

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

    func rotate(_ item: LibraryItem, quarterTurns: Int) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].settings.rotate(by: quarterTurns)
        items[i].isCustomized = true
        refreshThumbnail(item.id)
    }

    func delete(_ item: LibraryItem) {
        guard !activeEditorIDs.contains(item.id) else { return }
        items.removeAll { $0.id == item.id }
        itemIDs.remove(item.id)
        thumbnails[item.id] = nil
        thumbnailLRU.removeAll { $0 == item.id }
        thumbnailRevisions[item.id] = nil
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

        exportGeneration &+= 1
        let generation = exportGeneration
        exportProgress = (0, snapshot.count)
        defer {
            if exportGeneration == generation {
                exportGeneration &+= 1
                exportProgress = nil
            }
        }

        let jobs = snapshot.map { item in
            let format = item.exportFormat(preferred: item.settings.exportFormat)
            return RenderEngine.ExportJob(
                url: item.url, settings: item.settings, format: format,
                outputURL: Paths.exportURL(stem: item.fileStem, fileExtension: format.fileExtension))
        }
        return try await engine.exportBatch(jobs) { [weak self] done, total in
            Task { @MainActor in
                // Strictly-increasing: equal re-sets would re-render the glass
                // progress card multiple times per frame for nothing.
                    guard let self, self.exportGeneration == generation,
                        done > (self.exportProgress?.done ?? -1) else { return }
                self.exportProgress = (done, total)
            }
        }
    }

    // MARK: - Thumbnails

    func ensureThumbnail(_ item: LibraryItem) {
        // Copies own the storage bandwidth during import. Visible cells retry
        // once the batch completes (their task id includes `isImporting`).
        guard !isImporting else { return }
        guard thumbnails[item.id] == nil else { touchThumbnail(item.id); return }
        guard !thumbnailTasks.contains(item.id) else { return }
        thumbnailTasks.insert(item.id)
        let id = item.id
        let revision = nextThumbnailRevision(for: id)
        Task {
            defer { thumbnailTasks.remove(id) }
            // check session disk cache first
            if let cached = await Self.loadThumbnail(id) {
                if itemIDs.contains(id), thumbnailRevisions[id] == revision {
                    storeThumbnail(cached, for: id)
                }
                return
            }
            await renderThumbnailNow(item, revision: revision)
        }
    }

    func refreshThumbnail(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        renderThumbnail(item)
    }

    func adoptThumbnail(from preview: CGImage, for id: UUID) {
        guard itemIDs.contains(id) else { return }
        let source = RenderedImage(cgImage: preview)
        let revision = nextThumbnailRevision(for: id)
        Task {
            let thumbnail = await engine.downscale(source, maxDimension: 700)
            guard itemIDs.contains(id), thumbnailRevisions[id] == revision else { return }
            storeThumbnail(thumbnail.cgImage, for: id)
            Self.persistThumbnail(thumbnail.cgImage, for: id, revision: revision)
        }
    }

    private func renderThumbnail(_ item: LibraryItem) {
        guard !thumbnailTasks.contains(item.id) else { return }
        thumbnailTasks.insert(item.id)
        let revision = nextThumbnailRevision(for: item.id)
        Task {
            defer { thumbnailTasks.remove(item.id) }
            await renderThumbnailNow(item, revision: revision)
        }
    }

    private func renderThumbnailNow(_ item: LibraryItem, revision: UInt64) async {
        // Re-render until the item's settings are stable, so an edit (e.g. a
        // rotate) landing while a render is in flight is never lost.
        var settings = items.first(where: { $0.id == item.id })?.settings ?? item.settings
        while true {
            #if os(iOS)
            // wait for a return to foreground before rendering (no GPU off foreground)
            await Self.waitUntilForeground()
            #endif
            let rendered = try? await engine.thumbnail(url: item.url, settings: settings, maxDimension: 700)
            guard itemIDs.contains(item.id), thumbnailRevisions[item.id] == revision else { return }
            if let latest = items.first(where: { $0.id == item.id })?.settings, latest != settings {
                settings = latest
                continue
            }
            #if os(iOS)
            if UIApplication.shared.applicationState == .background { continue }
            #endif
            guard let cg = rendered?.cgImage else { return }
            storeThumbnail(cg, for: item.id)
            Self.persistThumbnail(cg, for: item.id, revision: revision)
            return
        }
    }

    private func nextThumbnailRevision(for id: UUID) -> UInt64 {
        let revision = (thumbnailRevisions[id] ?? 0) &+ 1
        thumbnailRevisions[id] = revision
        return revision
    }

    #if os(iOS)
    @MainActor
    private static func waitUntilForeground() async {
        while UIApplication.shared.applicationState == .background {
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didBecomeActiveNotification) { break }
        }
    }
    #endif

    private func storeThumbnail(_ image: CGImage, for id: UUID) {
        thumbnails[id] = image
        touchThumbnail(id)
        while thumbnails.count > Self.thumbnailCap, let coldest = thumbnailLRU.first {
            thumbnailLRU.removeFirst()
            thumbnails[coldest] = nil
        }
    }

    nonisolated private static func persistThumbnail(_ image: CGImage, for id: UUID,
                                                     revision: UInt64) {
        let rendered = RenderedImage(cgImage: image)
        Task.detached(priority: .utility) {
            await ThumbnailCacheWriter.shared.write(rendered, for: id, revision: revision)
        }
    }

    nonisolated private static func loadThumbnail(_ id: UUID) async -> CGImage? {
        let url = Paths.thumbnail(id)
        return await Task.detached(priority: .utility) {
            // Decode off-main so the first draw doesn't pay it.
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }.value
    }

    private func touchThumbnail(_ id: UUID) {
        if let i = thumbnailLRU.firstIndex(of: id) { thumbnailLRU.remove(at: i) }
        thumbnailLRU.append(id)
    }
}
