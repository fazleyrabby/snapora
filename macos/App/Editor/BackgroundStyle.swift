import AppKit
import SwiftUI

// MARK: - Style model

struct BGColor: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255,
                  b: Double(hex & 0xFF) / 255)
    }

    init(_ ns: NSColor) {
        let c = ns.usingColorSpace(.sRGB) ?? ns
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent),
                  a: Double(c.alphaComponent))
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(nsColor: nsColor) }
}

struct GradientSpec: Codable, Equatable, Hashable {
    var name: String?
    var start: BGColor
    var end: BGColor
    /// CSS convention: 0 = towards the top, 90 = towards the right, 180 = down.
    var angle: Double
}

enum BackgroundFill: Codable, Equatable {
    case transparent
    case solid(BGColor)
    case gradient(GradientSpec)
}

enum BackgroundAspect: String, Codable, CaseIterable, Identifiable {
    case auto, wide16x9, standard4x3, square, portrait9x16, photo3x2

    var id: Self { self }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .wide16x9: "16:9"
        case .standard4x3: "4:3"
        case .square: "1:1"
        case .portrait9x16: "9:16"
        case .photo3x2: "3:2"
        }
    }

    /// width / height, or nil for "fit the content plus padding".
    var ratio: Double? {
        switch self {
        case .auto: nil
        case .wide16x9: 16.0 / 9
        case .standard4x3: 4.0 / 3
        case .square: 1
        case .portrait9x16: 9.0 / 16
        case .photo3x2: 3.0 / 2
        }
    }
}

enum BackgroundAlignment: String, Codable, CaseIterable, Identifiable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    var id: Self { self }

    /// 0 = leading edge, 0.5 = centred, 1 = trailing edge.
    var horizontal: Double {
        switch self {
        case .topLeft, .left, .bottomLeft: 0
        case .top, .center, .bottom: 0.5
        case .topRight, .right, .bottomRight: 1
        }
    }

    var vertical: Double {
        switch self {
        case .topLeft, .top, .topRight: 0
        case .left, .center, .right: 0.5
        case .bottomLeft, .bottom, .bottomRight: 1
        }
    }
}

struct BackgroundShadow: Codable, Equatable {
    var enabled = true
    /// Blur radius in output pixels.
    var radius: Double = 40
    var opacity: Double = 0.35
}

struct BackgroundStyle: Codable, Equatable {
    static let defaultsKey = "editorBackgroundStyle"
    static let paddingRange: ClosedRange<Double> = 0...400
    static let cornerRange: ClosedRange<Double> = 0...48
    static let shadowRadiusRange: ClosedRange<Double> = 0...120

    var enabled = false
    var fill: BackgroundFill = .gradient(BackgroundPresets.gradients[6])
    /// Pixels of background around the image (in output image pixels).
    var padding: Double = 64
    /// Corner radius applied to the screenshot itself, in image pixels.
    var cornerRadius: Double = 12
    var shadow = BackgroundShadow()
    var aspect: BackgroundAspect = .auto
    var alignment: BackgroundAlignment = .center

    var clamped: BackgroundStyle {
        var s = self
        s.padding = min(max(padding, Self.paddingRange.lowerBound), Self.paddingRange.upperBound)
        s.cornerRadius = min(max(cornerRadius, Self.cornerRange.lowerBound), Self.cornerRange.upperBound)
        s.shadow.radius = min(max(shadow.radius, Self.shadowRadiusRange.lowerBound), Self.shadowRadiusRange.upperBound)
        s.shadow.opacity = min(max(shadow.opacity, 0), 1)
        return s
    }

    static func loadSaved() -> BackgroundStyle {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let style = try? JSONDecoder().decode(BackgroundStyle.self, from: data) else { return BackgroundStyle() }
        return style.clamped
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    /// Canvas size and where the edited image sits inside it.
    func layout(contentSize: CGSize) -> BackgroundLayout {
        guard enabled else { return .plain(contentSize) }
        let p = padding.rounded()
        var w = contentSize.width + 2 * p
        var h = contentSize.height + 2 * p
        if let r = aspect.ratio {
            if w / h < r { w = h * r } else { h = w / r }
        }
        w = w.rounded(.up)
        h = h.rounded(.up)
        let ox = p + ((w - 2 * p - contentSize.width) * alignment.horizontal).rounded()
        let oy = p + ((h - 2 * p - contentSize.height) * alignment.vertical).rounded()
        return BackgroundLayout(canvasSize: CGSize(width: w, height: h), contentOrigin: CGPoint(x: ox, y: oy))
    }
}

/// Where the edited image sits inside the styled canvas (both y-down pixels).
struct BackgroundLayout: Equatable {
    var canvasSize: CGSize
    var contentOrigin: CGPoint

    static func plain(_ size: CGSize) -> BackgroundLayout { BackgroundLayout(canvasSize: size, contentOrigin: .zero) }
}

// MARK: - Presets

enum BackgroundPresets {
    private static func g(_ name: String, _ a: UInt32, _ b: UInt32, _ angle: Double) -> GradientSpec {
        GradientSpec(name: name, start: BGColor(hex: a), end: BGColor(hex: b), angle: angle)
    }

    static let gradients: [GradientSpec] = [
        g("Sunset", 0xFF9966, 0xFF5E62, 135),
        g("Ocean", 0x2193B0, 0x6DD5ED, 135),
        g("Lavender", 0xA18CD1, 0xFBC2EB, 135),
        g("Mint", 0x43C6AC, 0xF8FFAE, 135),
        g("Midnight", 0x0F2027, 0x2C5364, 135),
        g("Peach", 0xFFECD2, 0xFCB69F, 135),
        g("Indigo", 0x667EEA, 0x764BA2, 135),
        g("Aurora", 0x00C9FF, 0x92FE9D, 135),
    ]

    static let solids: [BGColor] = [
        BGColor(hex: 0xFFFFFF), BGColor(hex: 0xE5E5EA), BGColor(hex: 0x1C1C1E),
        BGColor(hex: 0x0A84FF), BGColor(hex: 0xFF6482), BGColor(hex: 0x30D158),
    ]
}

// MARK: - Rendering (shared by canvas preview and export)

enum BackgroundRenderer {
    /// Draws the styled canvas. The caller's CTM maps canvas pixels (top-left
    /// origin, y down) to the destination. `content` is called with the CTM
    /// translated so that (0,0) is the image's top-left, inside a rounded clip,
    /// and must draw `contentSize` pixels.
    static func draw(in ctx: CGContext, style: BackgroundStyle, layout: BackgroundLayout,
                     contentSize: CGSize, content: (CGContext) -> Void) {
        let style = style.clamped
        let canvas = CGRect(origin: .zero, size: layout.canvasSize)
        ctx.saveGState()
        ctx.clip(to: canvas)
        fill(ctx, style.fill, in: canvas)

        let imageRect = CGRect(origin: layout.contentOrigin, size: contentSize)
        let radius = min(style.cornerRadius, min(imageRect.width, imageRect.height) / 2)

        if style.shadow.enabled, style.shadow.opacity > 0 {
            drawShadow(ctx, imageRect: imageRect, cornerRadius: radius, shadow: style.shadow)
        }

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.translateBy(x: imageRect.minX, y: imageRect.minY)
        content(ctx)
        ctx.restoreGState()
        ctx.restoreGState()
    }

    /// Draws `image` upright into `rect` of a y-down context.
    static func drawImage(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private static func fill(_ ctx: CGContext, _ fill: BackgroundFill, in rect: CGRect) {
        switch fill {
        case .transparent:
            break
        case .solid(let c):
            ctx.setFillColor(c.cgColor)
            ctx.fill(rect)
        case .gradient(let spec):
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let gradient = CGGradient(colorsSpace: space, colors: [spec.start.cgColor, spec.end.cgColor] as CFArray,
                                            locations: [0, 1]) else { return }
            let a = spec.angle * .pi / 180
            let dir = CGPoint(x: sin(a), y: -cos(a))
            let len = abs(rect.width * dir.x) + abs(rect.height * dir.y)
            let mid = CGPoint(x: rect.midX, y: rect.midY)
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: mid.x - dir.x * len / 2, y: mid.y - dir.y * len / 2),
                                   end: CGPoint(x: mid.x + dir.x * len / 2, y: mid.y + dir.y * len / 2),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    // MARK: Shadow

    private struct ShadowKey: Hashable {
        var w: Int, h: Int, radius: Int, corner: Int, opacity: Int
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedKey: ShadowKey?
    nonisolated(unsafe) private static var cachedImage: CGImage?

    /// The drop shadow is rendered once into a (possibly downscaled) offscreen
    /// bitmap, where CoreGraphics' shadow parameters are well defined, then
    /// drawn into the target. This keeps preview and export identical
    /// regardless of the destination context's scale.
    private static func drawShadow(_ ctx: CGContext, imageRect: CGRect, cornerRadius: CGFloat, shadow: BackgroundShadow) {
        let blur = shadow.radius
        let dy = (blur * 0.4).rounded()
        let margin = ceil(blur * 1.6 + dy) + 2
        let key = ShadowKey(w: Int(imageRect.width), h: Int(imageRect.height), radius: Int(blur.rounded()),
                            corner: Int(cornerRadius.rounded()), opacity: Int((shadow.opacity * 1000).rounded()))

        cacheLock.lock()
        var image = cachedKey == key ? cachedImage : nil
        cacheLock.unlock()

        if image == nil {
            let fullW = imageRect.width + 2 * margin
            let fullH = imageRect.height + 2 * margin
            let s = min(1, 1200 / max(fullW, fullH))
            let pw = max(Int(ceil(fullW * s)), 1)
            let ph = max(Int(ceil(fullH * s)), 1)
            if let bmp = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                bmp.scaleBy(x: s, y: s)
                // Draw the caster far off-bitmap and offset its shadow back in,
                // so only the shadow (not the caster) lands in the bitmap.
                let far = fullW + 200
                bmp.setShadow(offset: CGSize(width: far * s, height: -dy * s), blur: blur * s,
                              color: CGColor(gray: 0, alpha: shadow.opacity))
                bmp.setFillColor(CGColor(gray: 0, alpha: 1))
                let rect = CGRect(x: margin - far, y: margin, width: imageRect.width, height: imageRect.height)
                bmp.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
                bmp.fillPath()
                image = bmp.makeImage()
            }
            cacheLock.lock()
            cachedKey = key
            cachedImage = image
            cacheLock.unlock()
        }
        guard let image else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        drawImage(ctx, image, in: imageRect.insetBy(dx: -margin, dy: -margin))
        ctx.restoreGState()
    }
}
