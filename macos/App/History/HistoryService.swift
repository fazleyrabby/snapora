import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class HistoryService: ObservableObject {
    static let shared = HistoryService()

    static let retentionKey = "historyRetentionDays"

    @Published private(set) var items: [CaptureRecord] = []
    @Published var search: String = "" { didSet { if oldValue != search { refresh() } } }
    @Published var kindFilter: CaptureKind? = nil { didSet { if oldValue != kindFilter { refresh() } } }
    @Published var favoritesOnly: Bool = false { didSet { if oldValue != favoritesOnly { refresh() } } }

    private var db: HistoryDb?
    private var pathToId: [String: Int64] = [:]

    var isAvailable: Bool { db != nil }

    var retentionDays: Int {
        get { UserDefaults.standard.integer(forKey: Self.retentionKey) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: Self.retentionKey) }
    }

    nonisolated static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Snapora", isDirectory: true)
    }
    nonisolated static var thumbnailsDirectory: URL { supportDirectory.appendingPathComponent("Thumbnails", isDirectory: true) }

    private init() {
        do {
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: Self.thumbnailsDirectory, withIntermediateDirectories: true)
            db = try HistoryDb.open(path: Self.supportDirectory.appendingPathComponent("history.sqlite").path)
        } catch {
            NSLog("Snapora: history database unavailable (\(error)); running without history")
            db = nil
        }
        runMaintenance()
        refresh()
    }

    // MARK: - Maintenance

    /// Applies retention and prunes rows whose media is gone. Safe to call repeatedly.
    func runMaintenance() {
        guard let db else { return }
        do { _ = try db.pruneMissing() } catch { NSLog("Snapora: pruneMissing failed: \(error)") }
        let days = retentionDays
        if days > 0 {
            let policy = HistoryRetentionPolicy(maxAgeDays: UInt32(days), maxItems: nil, keepFavorites: true)
            do {
                let removed = try db.applyRetention(policy: policy, nowUnix: Int64(Date().timeIntervalSince1970))
                for r in removed { deleteFiles(of: r) }
            } catch { NSLog("Snapora: retention failed: \(error)") }
        }
    }

    // MARK: - Recording

    func recordScreenshot(url: URL, pixelSize: CGSize) {
        insert(url: url, kind: .screenshot, pixelSize: pixelSize, duration: nil)
    }

    func recordVideo(url: URL, kind: CaptureKind, pixelSize: CGSize, duration: TimeInterval) {
        insert(url: url, kind: kind, pixelSize: pixelSize, duration: duration)
    }

    private func insert(url: URL, kind: CaptureKind, pixelSize: CGSize, duration: TimeInterval?) {
        guard let db else { return }
        let rec = NewCaptureRecord(
            kind: kind, filePath: url.path, thumbnailPath: nil,
            width: UInt32(max(0, pixelSize.width)), height: UInt32(max(0, pixelSize.height)),
            durationMs: duration.map { UInt64(max(0, $0) * 1000) },
            createdAt: Int64(Date().timeIntervalSince1970), title: nil, ocrText: nil)
        do {
            let id = try db.insert(record: rec)
            pathToId[url.path] = id
            refresh()
            let isVideo = kind != .screenshot
            Task { [weak self] in
                let thumb = await Self.makeThumbnail(source: url, id: id, isVideo: isVideo)
                guard let thumb, let self else { return }
                try? self.db?.setThumbnail(id: id, path: thumb.path)
                self.refresh()
            }
        } catch {
            NSLog("Snapora: history insert failed: \(error)")
        }
    }

    func recordId(for url: URL) -> Int64? {
        if let id = pathToId[url.path] { return id }
        guard let db, let all = try? db.list(query: HistoryQuery(limit: 2000)) else { return nil }
        for r in all { pathToId[r.filePath] = r.id }
        return pathToId[url.path]
    }

    func setOCRText(url: URL, text: String?) {
        guard let id = recordId(for: url) else { return }
        setOCRText(id: id, text: text)
    }

    func setOCRText(id: Int64, text: String?) {
        try? db?.setOcrText(id: id, text: text)
        if !search.isEmpty { refresh() }
    }

    // MARK: - Queries / mutations

    func refresh() {
        guard let db else { items = []; return }
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = HistoryQuery(kind: kindFilter, favoritesOnly: favoritesOnly,
                             search: trimmed.isEmpty ? nil : trimmed, limit: 500, offset: 0)
        do {
            items = try db.list(query: q)
            for r in items { pathToId[r.filePath] = r.id }
        } catch {
            NSLog("Snapora: history list failed: \(error)")
        }
    }

    func toggleFavorite(_ record: CaptureRecord) {
        try? db?.setFavorite(id: record.id, favorite: !record.favorite)
        refresh()
    }

    func delete(_ record: CaptureRecord) {
        _ = try? db?.delete(id: record.id)
        pathToId[record.filePath] = nil
        deleteFiles(of: record)
        refresh()
    }

    /// Removes the DB row only (used for missing files).
    func removeRecordOnly(_ record: CaptureRecord) {
        _ = try? db?.delete(id: record.id)
        pathToId[record.filePath] = nil
        if let t = record.thumbnailPath { removeIfManaged(URL(fileURLWithPath: t)) }
        refresh()
    }

    // MARK: - Files

    static func isManaged(_ url: URL) -> Bool {
        let root = supportDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root)
    }

    private func removeIfManaged(_ url: URL) {
        guard Self.isManaged(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func deleteFiles(of r: CaptureRecord) {
        removeIfManaged(URL(fileURLWithPath: r.filePath))
        if let t = r.thumbnailPath { removeIfManaged(URL(fileURLWithPath: t)) }
    }

    // MARK: - Thumbnails

    nonisolated private static func makeThumbnail(source: URL, id: Int64, isVideo: Bool) async -> URL? {
        let out = thumbnailsDirectory.appendingPathComponent("\(id).jpg")
        let cg: CGImage?
        if isVideo {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 400, height: 400)
            cg = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        } else {
            guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
            cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 400,
            ] as CFDictionary)
        }
        guard let cg,
              let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out : nil
    }
}
