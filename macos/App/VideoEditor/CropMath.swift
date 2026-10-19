import CoreGraphics
import Foundation

/// Aspect-ratio presets for the crop tool.
enum CropAspect: String, CaseIterable, Identifiable {
    case free, r16x9, r4x3, r1x1, r9x16

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Free"
        case .r16x9: "16:9"
        case .r4x3: "4:3"
        case .r1x1: "1:1"
        case .r9x16: "9:16"
        }
    }

    /// width / height, or nil for free-form.
    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .r16x9: 16.0 / 9.0
        case .r4x3: 4.0 / 3.0
        case .r1x1: 1
        case .r9x16: 9.0 / 16.0
        }
    }
}

/// Pure crop-rectangle geometry. All rects use a top-left origin in video
/// pixel coordinates.
enum CropMath {
    /// Smallest crop edge (video pixels) the UI allows.
    static let minSize: CGFloat = 16

    /// Returns `rect` forced to lie inside `bounds` and, when `aspect`
    /// (width / height) is given, shrunk (never grown) to match it. The
    /// result keeps `rect`'s origin where possible and is translated back
    /// inside `bounds` if needed.
    static func constrain(rect: CGRect, aspect: CGFloat?, bounds: CGRect) -> CGRect {
        let r = rect.standardized
        var w = min(r.width, bounds.width)
        var h = min(r.height, bounds.height)
        if let a = aspect, a > 0, w > 0, h > 0 {
            if w / h > a { w = h * a } else { h = w / a }
        }
        let x = min(max(r.minX, bounds.minX), bounds.maxX - w)
        let y = min(max(r.minY, bounds.minY), bounds.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Rectangle spanned by dragging from a fixed `anchor` corner to `point`,
    /// clamped to `bounds` and honouring `aspect` (width / height).
    static func rect(anchor: CGPoint, point: CGPoint, aspect: CGFloat?, bounds: CGRect) -> CGRect {
        let a = clamp(anchor, to: bounds)
        let p = clamp(point, to: bounds)
        let dx = p.x - a.x
        let dy = p.y - a.y
        var w = abs(dx)
        var h = abs(dy)
        if let asp = aspect, asp > 0 {
            let availW = dx >= 0 ? bounds.maxX - a.x : a.x - bounds.minX
            let availH = dy >= 0 ? bounds.maxY - a.y : a.y - bounds.minY
            w = min(max(w, h * asp), availW, availH * asp)
            h = w / asp
        }
        let x = dx >= 0 ? a.x : a.x - w
        let y = dy >= 0 ? a.y : a.y - h
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Default crop: centered, 80% of the bounds, matching `aspect`.
    static func defaultRect(aspect: CGFloat?, bounds: CGRect) -> CGRect {
        let w = bounds.width * 0.8
        let h = bounds.height * 0.8
        let r = CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        let c = constrain(rect: r, aspect: aspect, bounds: bounds)
        return CGRect(x: bounds.midX - c.width / 2, y: bounds.midY - c.height / 2, width: c.width, height: c.height)
    }

    /// Integer, even-sized rect suitable for video encoding, inside `bounds`.
    static func encodable(_ rect: CGRect, bounds: CGRect) -> CGRect {
        let c = constrain(rect: rect, aspect: nil, bounds: bounds)
        let w = max(2, (c.width / 2).rounded(.down) * 2)
        let h = max(2, (c.height / 2).rounded(.down) * 2)
        let x = min(c.minX.rounded(.down), bounds.maxX - w)
        let y = min(c.minY.rounded(.down), bounds.maxY - h)
        return CGRect(x: max(0, x), y: max(0, y), width: w, height: h)
    }

    private static func clamp(_ p: CGPoint, to b: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }
}
