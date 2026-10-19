import AppKit

/// Swift-side helpers for annotation values (the Rust core owns hit-testing
/// and bounds estimates; these cover what the UI needs for editing).
extension AnnotationKind {
    /// The rectangle that defines region-like kinds, if any.
    var regionRect: Rect? {
        switch self {
        case .rectangle(let r), .ellipse(let r), .highlight(let r), .spotlight(let r), .redact(let r):
            return r
        case .blur(let r, _), .pixelate(let r, _):
            return r
        default:
            return nil
        }
    }

    func withRegionRect(_ r: Rect) -> AnnotationKind {
        switch self {
        case .rectangle: return .rectangle(rect: r)
        case .ellipse: return .ellipse(rect: r)
        case .highlight: return .highlight(rect: r)
        case .spotlight: return .spotlight(rect: r)
        case .redact: return .redact(rect: r)
        case .blur(_, let radius): return .blur(rect: r, radius: radius)
        case .pixelate(_, let block): return .pixelate(rect: r, blockSize: block)
        default: return self
        }
    }

    var isDestructive: Bool {
        switch self {
        case .blur, .pixelate, .redact: return true
        default: return false
        }
    }

    func translated(dx: Double, dy: Double) -> AnnotationKind {
        func mv(_ p: EditorPoint) -> EditorPoint { EditorPoint(x: p.x + dx, y: p.y + dy) }
        func mv(_ r: Rect) -> Rect { Rect(x: r.x + dx, y: r.y + dy, width: r.width, height: r.height) }
        switch self {
        case .arrow(let s, let e): return .arrow(start: mv(s), end: mv(e))
        case .line(let s, let e): return .line(start: mv(s), end: mv(e))
        case .rectangle(let r): return .rectangle(rect: mv(r))
        case .ellipse(let r): return .ellipse(rect: mv(r))
        case .text(let o, let t): return .text(origin: mv(o), text: t)
        case .freehand(let pts): return .freehand(points: pts.map(mv))
        case .counter(let c, let n): return .counter(center: mv(c), number: n)
        case .highlight(let r): return .highlight(rect: mv(r))
        case .spotlight(let r): return .spotlight(rect: mv(r))
        case .blur(let r, let rad): return .blur(rect: mv(r), radius: rad)
        case .pixelate(let r, let b): return .pixelate(rect: mv(r), blockSize: b)
        case .redact(let r): return .redact(rect: mv(r))
        }
    }
}

extension Annotation {
    func translated(dx: Double, dy: Double) -> Annotation {
        Annotation(id: id, kind: kind.translated(dx: dx, dy: dy), style: style)
    }

    /// Bounding box in source pixels, used for the selection outline.
    var selectionBounds: CGRect {
        let half = max(style.lineWidth, 0) / 2
        switch kind {
        case .arrow(let s, let e):
            return CGRect(from: s.cgPoint, to: e.cgPoint).insetBy(dx: -max(half, style.lineWidth * 2), dy: -max(half, style.lineWidth * 2))
        case .line(let s, let e):
            return CGRect(from: s.cgPoint, to: e.cgPoint).insetBy(dx: -half, dy: -half)
        case .rectangle(let r), .ellipse(let r):
            return r.cgRect.standardized.insetBy(dx: -half, dy: -half)
        case .text(let o, let t):
            let size = AnnotationRenderer.textSize(t, fontSize: style.fontSize)
            return CGRect(origin: o.cgPoint, size: size)
        case .freehand(let pts):
            guard let first = pts.first else { return .null }
            var r = CGRect(origin: first.cgPoint, size: .zero)
            for p in pts { r = r.union(CGRect(origin: p.cgPoint, size: .zero)) }
            return r.insetBy(dx: -half, dy: -half)
        case .counter(let c, _):
            let r = style.fontSize * 0.9
            return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .highlight(let r), .spotlight(let r), .redact(let r):
            return r.cgRect.standardized
        case .blur(let r, _), .pixelate(let r, _):
            return r.cgRect.standardized
        }
    }
}

extension CGRect {
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

/// Resize handle on a rectangle: `dx`/`dy` in -1...1 pick the moving edges.
struct RectHandle: Equatable {
    let dx: Int
    let dy: Int

    static let all: [RectHandle] = [-1, 0, 1].flatMap { dy in
        [-1, 0, 1].compactMap { dx in (dx == 0 && dy == 0) ? nil : RectHandle(dx: dx, dy: dy) }
    }

    func position(in r: CGRect) -> CGPoint {
        CGPoint(x: r.minX + CGFloat(dx + 1) / 2 * r.width, y: r.minY + CGFloat(dy + 1) / 2 * r.height)
    }

    /// New rect when this handle is dragged to `p` (source space).
    func resized(_ r: CGRect, to p: CGPoint) -> CGRect {
        var x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
        if dx == -1 { x0 = p.x } else if dx == 1 { x1 = p.x }
        if dy == -1 { y0 = p.y } else if dy == 1 { y1 = p.y }
        return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
    }
}

/// Builds the annotation payload for a drag from `start` to `end` (source px).
enum AnnotationFactory {
    /// Blur radius scales with the region so it stays strong on Retina/6K captures.
    static func blurRadius(for rect: Rect) -> Double {
        let r = rect.cgRect.standardized
        let m = Double(min(r.width, r.height))
        return min(max(16, m / 4), 96)
    }

    static func pixelateBlock(for rect: Rect) -> UInt32 {
        let r = rect.cgRect.standardized
        let m = Double(min(r.width, r.height))
        return UInt32(min(max(16, Int(m / 6)), 128))
    }

    static func kind(for tool: EditorTool, start: CGPoint, end: CGPoint, points: [CGPoint]) -> AnnotationKind? {
        let rect = Rect(CGRect(from: start, to: end))
        let tooSmall = hypot(end.x - start.x, end.y - start.y) < 3
        switch tool {
        case .arrow where !tooSmall: return .arrow(start: EditorPoint(start), end: EditorPoint(end))
        case .line where !tooSmall: return .line(start: EditorPoint(start), end: EditorPoint(end))
        case .rectangle where !tooSmall: return .rectangle(rect: rect)
        case .ellipse where !tooSmall: return .ellipse(rect: rect)
        case .highlight where !tooSmall: return .highlight(rect: rect)
        case .spotlight where !tooSmall: return .spotlight(rect: rect)
        case .blur where !tooSmall: return .blur(rect: rect, radius: blurRadius(for: rect))
        case .pixelate where !tooSmall: return .pixelate(rect: rect, blockSize: pixelateBlock(for: rect))
        case .redact where !tooSmall: return .redact(rect: rect)
        case .freehand where points.count >= 2: return .freehand(points: points.map(EditorPoint.init))
        default: return nil
        }
    }

    /// Shift-constraint: 45-degree snap for lines, square for boxes.
    static func constrained(_ tool: EditorTool, start: CGPoint, end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        switch tool {
        case .arrow, .line:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * len, y: start.y + sin(angle) * len)
        case .rectangle, .ellipse, .highlight, .spotlight, .blur, .pixelate, .redact:
            let m = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -m : m), y: start.y + (dy < 0 ? -m : m))
        default:
            return end
        }
    }
}
