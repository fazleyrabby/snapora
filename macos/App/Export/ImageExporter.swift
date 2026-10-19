import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportError: LocalizedError {
    case cannotCreateDestination
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .cannotCreateDestination: "Could not create the image file."
        case .writeFailed: "Could not write the image file."
        }
    }
}

enum ImageExporter {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Writes a PNG atomically (temp file + move) with a unique name from the
    /// Rust naming template.
    static func savePNG(_ image: CGImage, to directory: URL, template: String = defaultFileNameTemplate()) throws -> URL {
        let name = captureFileName(template: template, extension: "png")
        let target = uniqueURL(in: directory, fileName: name)
        let temp = directory.appendingPathComponent(".snapora-\(UUID().uuidString).png")

        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.cannotCreateDestination
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: temp)
            throw ExportError.writeFailed
        }
        do {
            try FileManager.default.moveItem(at: temp, to: target)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return target
    }

    static func uniqueURL(in directory: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}
