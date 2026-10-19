import AppKit
import UniformTypeIdentifiers

/// Opens files handed to Snapora (Finder "Open With", `open -a Snapora`):
/// images in the image editor, videos in the video editor.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                let type = UTType(filenameExtension: url.pathExtension.lowercased())
                if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
                    VideoEditor.open(url: url)
                } else if type?.conforms(to: .image) == true {
                    ImageEditor.open(url: url)
                }
            }
        }
    }
}
