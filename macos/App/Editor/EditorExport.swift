import AppKit
import ImageIO
import UniformTypeIdentifiers

enum EditorExportError: LocalizedError {
    case renderFailed
    case encodeFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .renderFailed: "Could not render the edited image."
        case .encodeFailed: "Could not encode the image."
        case .writeFailed: "Could not write the image file."
        }
    }
}

/// Flattens the document into a plain bitmap. Annotations (including
/// redact/blur/pixelate) are baked into pixels; no layers or metadata survive.
enum EditorExport {
    static func render(document: EditorDocument, source: CGImage, effects: EffectCache, opaqueWhite: Bool = false) throws -> CGImage {
        let transform = SourceTransform(sourceSize: CGSize(width: source.width, height: source.height),
                                        crop: document.crop()?.cgRect,
                                        quarterTurns: Int(document.rotation()))
        let w = max(Int(transform.outputSize.width.rounded()), 1)
        let h = max(Int(transform.outputSize.height.rounded()), 1)

        var space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let s = source.colorSpace, s.model == .rgb { space = s }
        let alpha: CGImageAlphaInfo = opaqueWhite ? .noneSkipFirst : .premultipliedFirst
        let info = alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info)
            ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
        else { throw EditorExportError.renderFailed }

        // y-down output space.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        if opaqueWhite {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        let annotations = document.annotations()
        AnnotationRenderer.render(in: ctx, source: source, annotations: annotations, transform: transform, cache: effects)
        guard let image = ctx.makeImage() else { throw EditorExportError.renderFailed }

        #if DEBUG
        verifyRedactions(image: image, document: document, annotations: annotations, transform: transform)
        #endif
        return image
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double = 0.9) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw EditorExportError.encodeFailed
        }
        var props: [CFString: Any] = [:]
        if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EditorExportError.encodeFailed }
        return data as Data
    }

    static func write(_ data: Data, to target: URL) throws {
        let temp = target.deletingLastPathComponent().appendingPathComponent(".snapora-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    #if DEBUG
    /// Debug-only: at least one sampled pixel of each redact region in the
    /// output must be opaque and match the redaction colour.
    private static func verifyRedactions(image: CGImage, document: EditorDocument, annotations: [Annotation], transform: SourceTransform) {
        let redacts = annotations.filter { if case .redact = $0.kind { return true } else { return false } }
        assert(document.destructiveRegions().count == annotations.filter { $0.kind.isDestructive }.count,
               "destructiveRegions() disagrees with annotation list")
        let outBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        for a in redacts {
            guard case .redact(let r) = a.kind else { continue }
            let region = transform.toOutput(r.cgRect.standardized).intersection(outBounds)
            if region.isNull || region.width < 1 || region.height < 1 { continue }
            let fractions: [(CGFloat, CGFloat)] = [(0.5, 0.5), (0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]
            let ok = fractions.contains { fx, fy in
                let p = CGPoint(x: min(region.minX + region.width * fx, region.maxX - 0.5),
                                y: min(region.minY + region.height * fy, region.maxY - 0.5))
                guard let px = pixel(image, at: p) else { return false }
                let want = a.style.stroke
                func close(_ got: UInt8, _ w: Float) -> Bool { abs(Int(got) - Int((w * 255).rounded())) <= 4 }
                return px.a == 255 && close(px.r, want.r) && close(px.g, want.g) && close(px.b, want.b)
            }
            assert(ok, "Redacted region is not opaque in exported pixels")
        }
    }

    private static func pixel(_ image: CGImage, at p: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        var buf = [UInt8](repeating: 0, count: 4)
        let drawn = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Bitmap contexts are y-up; image y is top-down.
            ctx.draw(image, in: CGRect(x: -floor(p.x), y: -(CGFloat(image.height) - floor(p.y) - 1),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        return drawn ? (buf[0], buf[1], buf[2], buf[3]) : nil
    }
    #endif
}

// MARK: - Model actions

extension EditorModel {
    private func renderForExport(opaqueWhite: Bool = false) -> CGImage? {
        flushStyle()
        do {
            return try EditorExport.render(document: document, source: source, effects: effects, opaqueWhite: opaqueWhite)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func copyToPasteboard() -> Bool {
        guard let image = renderForExport() else { return false }
        do {
            let png = try EditorExport.encode(image, type: .png)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(png, forType: .png)
            if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            statusMessage = "Copied to clipboard"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Writes "<name> edited.png" next to the source; the source stays untouched.
    func saveEdited() {
        guard let image = renderForExport() else { return }
        do {
            let png = try EditorExport.encode(image, type: .png)
            let dir = url.deletingLastPathComponent()
            let base = url.deletingPathExtension().lastPathComponent
            let target = ImageExporter.uniqueURL(in: dir, fileName: "\(base) edited.png")
            try EditorExport.write(png, to: target)
            statusMessage = "Saved \(target.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " edited.png"
        panel.directoryURL = url.deletingLastPathComponent()

        let slider = NSSlider(value: 0.9, minValue: 0.3, maxValue: 1.0, target: nil, action: nil)
        slider.frame = NSRect(x: 0, y: 0, width: 180, height: 20)
        let label = NSTextField(labelWithString: "JPEG quality")
        let stack = NSStackView(views: [label, slider])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = stack

        guard panel.runModal() == .OK, let target = panel.url else { return }
        let isJPEG = ["jpg", "jpeg"].contains(target.pathExtension.lowercased())
        guard let image = renderForExport(opaqueWhite: isJPEG) else { return }
        do {
            let data = try EditorExport.encode(image, type: isJPEG ? .jpeg : .png, quality: slider.doubleValue)
            try EditorExport.write(data, to: target)
            statusMessage = "Saved \(target.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func done() {
        if copyToPasteboard() { onClose?() }
    }

    /// Handles ⌘-shortcuts forwarded from the window. Returns true if consumed.
    func handleKeyEquivalent(_ event: NSEvent, textEditing: Bool) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard mods.contains(.command), mods.isDisjoint(with: [.control, .option]) else { return false }
        let shift = mods.contains(.shift)
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "z" where !textEditing: shift ? redo() : undo()
        case "c" where !textEditing: copyToPasteboard()
        case "s": shift ? saveAs() : saveEdited()
        case "=", "+": canvas?.zoomIn()
        case "-": canvas?.zoomOut()
        case "0": canvas?.zoomToFit()
        case "1": canvas?.zoomActualSize()
        case "w": onClose?()
        default: return false
        }
        return true
    }
}
