import AppKit

struct CaptureItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let pixelSize: CGSize
    let createdAt: Date
}

/// Persists every capture as a PNG in Application Support before any
/// further handling, and remembers the most recent one.
@MainActor
final class CaptureStore {
    static let shared = CaptureStore()

    private(set) var lastCapture: CaptureItem?

    static var capturesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Snapora/Captures", isDirectory: true)
    }

    func add(_ image: CGImage, template: String) throws -> CaptureItem {
        let dir = Self.capturesDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = try ImageExporter.savePNG(image, to: dir, template: template)
        let item = CaptureItem(
            id: UUID(), url: url,
            pixelSize: CGSize(width: image.width, height: image.height),
            createdAt: Date()
        )
        lastCapture = item
        return item
    }
}
