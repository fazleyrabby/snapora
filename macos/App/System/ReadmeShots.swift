#if DEBUG
import AppKit
import ScreenCaptureKit

/// Debug-only helper that stages Snapora's windows on sample content and
/// saves window screenshots for the README:
///
///     SNAPORA_README_SHOTS=<out dir> SNAPORA_README_SAMPLES=<dir with
///     "Sample Dashboard.png" and "Sample Recording.mp4"> Snapora
@MainActor
enum ReadmeShots {
    static func runIfRequested(quickAccess: QuickAccessController) {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["SNAPORA_README_SHOTS"], let samples = env["SNAPORA_README_SAMPLES"] else { return }
        let outDir = URL(fileURLWithPath: out, isDirectory: true)
        let image = URL(fileURLWithPath: samples).appendingPathComponent("Sample Dashboard.png")
        let video = URL(fileURLWithPath: samples).appendingPathComponent("Sample Recording.mp4")

        // Called during AppModel init; opening windows inside a SwiftUI update
        // aborts, so stage everything after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            stage(image: image, video: video, outDir: outDir, quickAccess: quickAccess)
        }
    }

    private static func stage(image: URL, video: URL, outDir: URL, quickAccess: QuickAccessController) {
        ImageEditor.debugSeed = seedAnnotations
        ImageEditor.open(url: image)
        VideoEditor.open(url: video)
        SettingsWindow.show()
        // No focused text field (its selection highlight looks odd in a screenshot).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.windows.first { $0.title == "Snapora Settings" }?.makeFirstResponder(nil)
        }
        quickAccess.show(CaptureItem(id: UUID(), url: image, pixelSize: CGSize(width: 1600, height: 1000), createdAt: Date()))

        Task {
            try? await Task.sleep(for: .seconds(4))
            await captureOwnWindows(to: outDir)
        }
    }

    private static func seedAnnotations(_ model: EditorModel) {
        let doc = model.document
        func color(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) -> AnnotationColor {
            AnnotationColor(r: r, g: g, b: b, a: a)
        }
        let red = color(0.95, 0.23, 0.29)
        func style(_ c: AnnotationColor, width: Double = 8, font: Double = 44, fill: AnnotationColor? = nil) -> AnnotationStyle {
            AnnotationStyle(stroke: c, fill: fill, lineWidth: width, fontSize: font)
        }
        _ = try? doc.addAnnotation(kind: .rectangle(rect: Rect(x: 312, y: 152, width: 406, height: 166)), style: style(red))
        _ = try? doc.addAnnotation(kind: .counter(center: EditorPoint(x: 712, y: 158), number: 1), style: style(red))
        _ = try? doc.addAnnotation(kind: .highlight(rect: Rect(x: 600, y: 182, width: 100, height: 36)),
                                   style: style(color(1, 0.85, 0.1, 0.45)))
        _ = try? doc.addAnnotation(kind: .redact(rect: Rect(x: 760, y: 212, width: 230, height: 64)), style: style(color(0.1, 0.1, 0.12)))
        _ = try? doc.addAnnotation(kind: .text(origin: EditorPoint(x: 1150, y: 352), text: "Best week!"), style: style(red, font: 48))
        _ = try? doc.addAnnotation(kind: .counter(center: EditorPoint(x: 1505, y: 380), number: 2), style: style(red))
        _ = try? doc.addAnnotation(kind: .arrow(start: EditorPoint(x: 1470, y: 430), end: EditorPoint(x: 1190, y: 560)), style: style(red, width: 10))
        model.reloadAnnotations()
    }

    private static func captureOwnWindows(to dir: URL) async {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let pid = ProcessInfo.processInfo.processIdentifier
            for window in content.windows where window.owningApplication?.processID == pid && window.frame.width > 100 {
                let image = try await ScreenCapture.capture(windowID: window.windowID, options: CaptureOptions(includeWindowShadow: true))
                let name = (window.title?.isEmpty == false ? window.title! : "window-\(window.windowID)")
                    .replacingOccurrences(of: "/", with: "-")
                let url = dir.appendingPathComponent("\(name).png")
                _ = try ImageExporter.savePNG(image, to: dir, template: name)
                FileHandle.standardError.write("readme shot: \(url.lastPathComponent) \(image.width)x\(image.height)\n".data(using: .utf8)!)
            }
        } catch {
            FileHandle.standardError.write("readme shots failed: \(error)\n".data(using: .utf8)!)
        }
        FileHandle.standardError.write("readme shots done\n".data(using: .utf8)!)
    }
}
#endif
