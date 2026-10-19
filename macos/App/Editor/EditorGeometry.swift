import CoreGraphics
import Foundation

/// Maps between source-image pixels and output pixels (after crop and
/// clockwise quarter-turn rotation). Both spaces are top-left origin, y down.
///
/// The document applies the crop in source space first, then rotates.
struct SourceTransform: Equatable {
    let sourceSize: CGSize
    let crop: CGRect?
    let quarterTurns: Int
    /// source pixels -> output pixels.
    let affine: CGAffineTransform
    let outputSize: CGSize

    init(sourceSize: CGSize, crop: CGRect?, quarterTurns: Int) {
        self.sourceSize = sourceSize
        self.crop = crop
        let turns = ((quarterTurns % 4) + 4) % 4
        self.quarterTurns = turns

        let area = crop ?? CGRect(origin: .zero, size: sourceSize)
        var t = CGAffineTransform(translationX: -area.minX, y: -area.minY)
        var w = area.width
        var h = area.height
        for _ in 0..<turns {
            // One clockwise turn of a w x h box: (x, y) -> (h - y, x).
            t = t.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0))
            swap(&w, &h)
        }
        self.affine = t
        self.outputSize = CGSize(width: w, height: h)
    }

    func toOutput(_ p: CGPoint) -> CGPoint { p.applying(affine) }
    func toSource(_ p: CGPoint) -> CGPoint { p.applying(affine.inverted()) }
    /// Bounding box of the mapped rect (exact for quarter turns).
    func toOutput(_ r: CGRect) -> CGRect { r.applying(affine) }
    func toSource(_ r: CGRect) -> CGRect { r.applying(affine.inverted()) }
}

/// Maps between output pixels and view points for a given zoom/pan.
struct ViewMapping: Equatable {
    /// View-space position of the output image's top-left corner.
    var origin: CGPoint
    /// View points per output pixel.
    var scale: CGFloat
    /// Offset (in output pixels) of the edited image inside the styled canvas
    /// (background padding/alignment). `origin` is the canvas's top-left;
    /// `toView`/`toOutput` map image-output pixels, so annotations keep image
    /// coordinates regardless of padding.
    var contentOffset: CGPoint = .zero

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + (p.x + contentOffset.x) * scale, y: origin.y + (p.y + contentOffset.y) * scale)
    }

    func toOutput(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) / scale - contentOffset.x, y: (p.y - origin.y) / scale - contentOffset.y)
    }

    func toView(_ r: CGRect) -> CGRect {
        CGRect(x: origin.x + (r.minX + contentOffset.x) * scale, y: origin.y + (r.minY + contentOffset.y) * scale,
               width: r.width * scale, height: r.height * scale)
    }

    /// `zoom` 1 means one image pixel per device pixel (100%), so on a 2x
    /// display one image pixel is 1/2 view point.
    static func scale(zoom: CGFloat, backingScale: CGFloat) -> CGFloat {
        zoom / max(backingScale, 1)
    }

    /// Zoom that fits the whole output into the viewport. Never upscales past 100%.
    static func fitZoom(outputSize: CGSize, viewport: CGSize, backingScale: CGFloat, padding: CGFloat = 24) -> CGFloat {
        guard outputSize.width > 0, outputSize.height > 0 else { return 1 }
        let availW = max(viewport.width - 2 * padding, 40)
        let availH = max(viewport.height - 2 * padding, 40)
        let z = min(availW * backingScale / outputSize.width, availH * backingScale / outputSize.height)
        return min(z, 1)
    }

    /// Origin that centers the output in the viewport, offset by `pan`.
    static func origin(outputSize: CGSize, viewport: CGSize, scale: CGFloat, pan: CGPoint) -> CGPoint {
        CGPoint(x: (viewport.width - outputSize.width * scale) / 2 + pan.x,
                y: (viewport.height - outputSize.height * scale) / 2 + pan.y)
    }
}

// MARK: - Rect helpers

extension Rect {
    init(_ r: CGRect) { self.init(x: r.origin.x, y: r.origin.y, width: r.width, height: r.height) }
}

extension EditorPoint {
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    init(_ p: CGPoint) { self.init(x: p.x, y: p.y) }
}

#if DEBUG
enum EditorGeometrySelfCheck {
    private static var done = false

    /// Cheap sanity checks of the coordinate maths; runs once in debug builds.
    static func runOnce() {
        guard !done else { return }
        done = true
        let t = SourceTransform(sourceSize: CGSize(width: 100, height: 50),
                                crop: CGRect(x: 10, y: 10, width: 40, height: 20), quarterTurns: 1)
        assert(t.outputSize == CGSize(width: 20, height: 40))
        // Top-left of the crop lands at the top-right after a clockwise turn.
        assert(t.toOutput(CGPoint(x: 10, y: 10)) == CGPoint(x: 20, y: 0))
        assert(t.toOutput(CGPoint(x: 50, y: 30)) == CGPoint(x: 0, y: 40))
        for p in [CGPoint(x: 12, y: 33), CGPoint(x: 49, y: 11)] {
            let q = t.toSource(t.toOutput(p))
            assert(abs(q.x - p.x) < 1e-9 && abs(q.y - p.y) < 1e-9)
        }
        let t3 = SourceTransform(sourceSize: CGSize(width: 100, height: 50), crop: nil, quarterTurns: 3)
        assert(t3.outputSize == CGSize(width: 50, height: 100))
        assert(t3.toOutput(CGPoint(x: 0, y: 0)) == CGPoint(x: 0, y: 100))
        // Retina: 100% zoom is half a point per pixel on a 2x display.
        let s = ViewMapping.scale(zoom: 1, backingScale: 2)
        let m = ViewMapping(origin: CGPoint(x: 10, y: 20), scale: s)
        assert(m.toView(CGPoint(x: 200, y: 100)) == CGPoint(x: 110, y: 70))
        assert(m.toOutput(CGPoint(x: 110, y: 70)) == CGPoint(x: 200, y: 100))
        // Background padding: image (0,0) sits at canvas (64,64).
        var padded = m
        padded.contentOffset = CGPoint(x: 64, y: 64)
        assert(padded.toView(CGPoint.zero) == CGPoint(x: 10 + 32, y: 20 + 32))
        assert(padded.toOutput(padded.toView(CGPoint(x: 7, y: 9))) == CGPoint(x: 7, y: 9))
    }
}
#endif
