import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Caches blur/pixelate results computed from the (immutable) source image.
///
/// Effects are always computed from the *source* pixels, so they can never
/// reveal anything drawn by other annotations.
final class EffectCache {
    let source: CGImage
    private var store: [AnnotationKind: CGImage] = [:]
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(source: CGImage) { self.source = source }

    /// Integral region of `rect` clipped to the source, or nil if empty.
    func region(for rect: Rect) -> CGRect? {
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let r = rect.cgRect.standardized.integral.intersection(bounds)
        return (r.isNull || r.width < 1 || r.height < 1) ? nil : r
    }

    func image(for kind: AnnotationKind) -> CGImage? {
        if let hit = store[kind] { return hit }
        let result: CGImage?
        switch kind {
        case .blur(let rect, let radius): result = makeBlur(rect: rect, radius: radius)
        case .pixelate(let rect, let block): result = makePixelate(rect: rect, block: block)
        default: result = nil
        }
        if let result {
            if store.count > 24 { store.removeAll() }
            store[kind] = result
        }
        return result
    }

    private func makeBlur(rect: Rect, radius: Double) -> CGImage? {
        guard let region = region(for: rect) else { return nil }
        let pad = (radius * 3).rounded(.up)
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let padded = region.insetBy(dx: -pad, dy: -pad).intersection(bounds)
        guard let sub = source.cropping(to: padded) else { return nil }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = CIImage(cgImage: sub).clampedToExtent()
        filter.radius = Float(radius)
        guard let out = filter.outputImage else { return nil }
        // Core Image uses a bottom-left origin.
        let ciRect = CGRect(x: region.minX - padded.minX,
                            y: padded.height - (region.minY - padded.minY) - region.height,
                            width: region.width, height: region.height)
        return Self.ciContext.createCGImage(out.cropped(to: ciRect), from: ciRect, format: .RGBA8,
                                            colorSpace: source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
    }

    private func makePixelate(rect: Rect, block: UInt32) -> CGImage? {
        guard let region = region(for: rect), let sub = source.cropping(to: region) else { return nil }
        let filter = CIFilter.pixellate()
        filter.inputImage = CIImage(cgImage: sub)
        filter.scale = Float(max(block, 2))
        filter.center = .zero
        guard let out = filter.outputImage else { return nil }
        let ciRect = CGRect(x: 0, y: 0, width: region.width, height: region.height)
        return Self.ciContext.createCGImage(out.cropped(to: ciRect), from: ciRect, format: .RGBA8,
                                            colorSpace: source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
    }
}

/// Draws the source image plus annotations. Shared by the canvas and export.
///
/// Contract: the caller's CTM maps *output pixels* (top-left origin, y down)
/// to the destination. The renderer applies the source->output transform.
/// Annotations with id 0 are live drafts: destructive ones render as a dashed
/// outline instead of running the (costly) effect.
enum AnnotationRenderer {
    static func render(in ctx: CGContext,
                       source: CGImage,
                       annotations: [Annotation],
                       transform: SourceTransform,
                       cache: EffectCache) {
        ctx.saveGState()
        ctx.concatenate(transform.affine)
        let srcW = CGFloat(source.width), srcH = CGFloat(source.height)
        if let crop = transform.crop { ctx.clip(to: crop) } else { ctx.clip(to: CGRect(x: 0, y: 0, width: srcW, height: srcH)) }

        drawImage(source, in: CGRect(x: 0, y: 0, width: srcW, height: srcH), ctx: ctx)
        for a in annotations {
            draw(a, in: ctx, sourceSize: CGSize(width: srcW, height: srcH), cache: cache)
        }
        ctx.restoreGState()
    }

    /// Draws an upright image into a y-down context.
    private static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    static func color(_ c: AnnotationColor, alpha: CGFloat? = nil) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: alpha ?? CGFloat(c.a))
    }

    static func font(size: Double) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }

    static func textSize(_ text: String, fontSize: Double) -> CGSize {
        let s = (text.isEmpty ? " " : text as NSString).size(withAttributes: [.font: font(size: fontSize)])
        return CGSize(width: ceil(s.width), height: ceil(s.height))
    }

    static func draw(_ a: Annotation, in ctx: CGContext, sourceSize: CGSize, cache: EffectCache) {
        let style = a.style
        let stroke = color(style.stroke)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(CGFloat(style.lineWidth))
        ctx.setStrokeColor(stroke)
        ctx.setFillColor(stroke)

        switch a.kind {
        case .arrow(let s, let e):
            drawArrow(ctx, from: s.cgPoint, to: e.cgPoint, lineWidth: CGFloat(style.lineWidth))

        case .line(let s, let e):
            ctx.move(to: s.cgPoint)
            ctx.addLine(to: e.cgPoint)
            ctx.strokePath()

        case .rectangle(let r):
            let rect = r.cgRect.standardized
            if let fill = style.fill {
                ctx.setFillColor(color(fill))
                ctx.fill(rect)
            }
            ctx.stroke(rect)

        case .ellipse(let r):
            let rect = r.cgRect.standardized
            if let fill = style.fill {
                ctx.setFillColor(color(fill))
                ctx.fillEllipse(in: rect)
            }
            ctx.strokeEllipse(in: rect)

        case .text(let origin, let text):
            drawText(text, at: origin.cgPoint, fontSize: style.fontSize, color: NSColor(cgColor: stroke) ?? .red, ctx: ctx)

        case .freehand(let pts):
            guard let first = pts.first else { break }
            if pts.count == 1 {
                let w = CGFloat(style.lineWidth)
                ctx.fillEllipse(in: CGRect(x: first.x - w / 2, y: first.y - w / 2, width: w, height: w))
            } else {
                ctx.move(to: first.cgPoint)
                for p in pts.dropFirst() { ctx.addLine(to: p.cgPoint) }
                ctx.strokePath()
            }

        case .counter(let c, let number):
            let r = CGFloat(style.fontSize * 0.9)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            let str = String(number)
            let f = NSFont.systemFont(ofSize: style.fontSize, weight: .bold)
            let size = (str as NSString).size(withAttributes: [.font: f])
            drawText(str, at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2),
                     font: f, color: .white, ctx: ctx)

        case .highlight(let r):
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(color(style.stroke, alpha: 0.35))
            ctx.fill(r.cgRect.standardized)

        case .spotlight(let r):
            let path = CGMutablePath()
            path.addRect(CGRect(origin: .zero, size: sourceSize))
            path.addRect(r.cgRect.standardized)
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
            ctx.fillPath(using: .evenOdd)

        case .redact(let r):
            if a.id == 0 {
                drawDraftOutline(ctx, rect: r.cgRect.standardized, tint: stroke)
            } else {
                // Always fully opaque: redaction must never leak what is beneath.
                ctx.setBlendMode(.normal)
                ctx.setFillColor(color(style.stroke, alpha: 1))
                ctx.fill(r.cgRect.standardized)
            }

        case .blur(let r, _), .pixelate(let r, _):
            if a.id == 0 {
                drawDraftOutline(ctx, rect: r.cgRect.standardized, tint: stroke)
            } else if let region = cache.region(for: r) {
                if let img = cache.image(for: a.kind) {
                    drawImage(img, in: region, ctx: ctx)
                } else {
                    // Effect failed: fail closed with an opaque fill, never the raw pixels.
                    ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
                    ctx.fill(region)
                }
            }
        }
    }

    private static func drawArrow(_ ctx: CGContext, from s: CGPoint, to e: CGPoint, lineWidth lw: CGFloat) {
        let dx = e.x - s.x, dy = e.y - s.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return }
        let ux = dx / len, uy = dy / len
        let headLen = min(max(lw * 3.5, 10), len)
        let halfW = headLen * 0.45
        let base = CGPoint(x: e.x - ux * headLen * 0.9, y: e.y - uy * headLen * 0.9)
        ctx.move(to: s)
        ctx.addLine(to: base)
        ctx.strokePath()
        ctx.move(to: e)
        ctx.addLine(to: CGPoint(x: base.x - uy * halfW, y: base.y + ux * halfW))
        ctx.addLine(to: CGPoint(x: base.x + uy * halfW, y: base.y - ux * halfW))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawDraftOutline(_ ctx: CGContext, rect: CGRect, tint: CGColor) {
        ctx.setFillColor(tint.copy(alpha: 0.15) ?? tint)
        ctx.fill(rect)
        ctx.setStrokeColor(tint)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.stroke(rect)
    }

    private static func drawText(_ text: String, at p: CGPoint, fontSize: Double, color: NSColor, ctx: CGContext) {
        drawText(text, at: p, font: font(size: fontSize), color: color, ctx: ctx)
    }

    private static func drawText(_ text: String, at p: CGPoint, font: NSFont, color: NSColor, ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        (text as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
        NSGraphicsContext.restoreGraphicsState()
    }
}
