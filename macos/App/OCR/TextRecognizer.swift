import CoreGraphics
import Vision

enum OCRError: LocalizedError {
    case noText

    var errorDescription: String? {
        switch self {
        case .noText: "No text found in the selected area."
        }
    }
}

/// On-device text recognition with Vision. Never logs recognized text.
enum TextRecognizer {
    static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = layout(request.results ?? [])
            if text.isEmpty { throw OCRError.noText }
            return text
        }.value
    }

    /// Orders observations top-to-bottom, left-to-right, joining fragments
    /// that share a visual line with spaces and separate lines with newlines.
    static func layout(_ observations: [VNRecognizedTextObservation]) -> String {
        struct Fragment { let text: String; let box: CGRect }
        let fragments = observations.compactMap { o -> Fragment? in
            guard let s = o.topCandidates(1).first?.string, !s.isEmpty else { return nil }
            return Fragment(text: s, box: o.boundingBox)
        }
        // Vision boxes are normalized with a bottom-left origin.
        let sorted = fragments.sorted { $0.box.midY > $1.box.midY }

        var lines: [[Fragment]] = []
        for f in sorted {
            if let last = lines.last?.first,
               abs(last.box.midY - f.box.midY) < min(last.box.height, f.box.height) * 0.5 {
                lines[lines.count - 1].append(f)
            } else {
                lines.append([f])
            }
        }
        return lines
            .map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }
}
