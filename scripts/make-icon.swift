// Renders the Snapora app icon set. Usage: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: ~80% body with rounded corners.
    let inset = s * 0.1
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.40, green: 0.30, blue: 0.98, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.10, green: 0.62, blue: 0.98, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    ctx.restoreGState()

    // Viewfinder corners.
    let f = body.insetBy(dx: body.width * 0.22, dy: body.width * 0.22)
    let arm = f.width * 0.28
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(max(1, s * 0.045))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for (corner, dx, dy) in [(CGPoint(x: f.minX, y: f.maxY), 1.0, -1.0), (CGPoint(x: f.maxX, y: f.maxY), -1.0, -1.0),
                             (CGPoint(x: f.minX, y: f.minY), 1.0, 1.0), (CGPoint(x: f.maxX, y: f.minY), -1.0, 1.0)] {
        ctx.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        ctx.addLine(to: corner)
        ctx.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
    }
    ctx.strokePath()

    // Shutter dot.
    let r = f.width * 0.13
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: f.midX - r, y: f.midY - r, width: 2 * r, height: 2 * r))

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
