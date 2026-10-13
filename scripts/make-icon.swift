// Draws the Focus app icon as vectors and writes a macOS .iconset.
// Usage: swift scripts/make-icon.swift <out.iconset>   (then: iconutil -c icns <out.iconset>)
//
// Design, on Apple's 1024 pt icon grid: a blue rounded square (824 pt, continuous corners) with a
// white mark of original geometry: a ring, four ticks and a centre dot.
import CoreGraphics
import Foundation
import ImageIO

let grid: CGFloat = 1024

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// A rounded rectangle with continuous corners (Apple's icon shape).
func shape(_ r: CGRect, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    func corner(_ c: CGPoint, _ d1: CGVector, _ d2: CGVector) {
        func p(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            CGPoint(x: c.x - a * radius * d1.dx + b * radius * d2.dx, y: c.y - a * radius * d1.dy + b * radius * d2.dy)
        }
        path.addLine(to: p(1.52866471, 0))
        path.addCurve(to: p(0.66993427, 0.06549600), control1: p(1.08849323, 0), control2: p(0.86840689, 0))
        path.addLine(to: p(0.63149399, 0.07491100))
        path.addCurve(to: p(0.07491176, 0.63149399), control1: p(0.37282392, 0.16905899), control2: p(0.16906013, 0.37282401))
        path.addCurve(to: p(0, 1.52866483), control1: p(0, 0.86840701), control2: p(0, 1.08849299))
    }
    path.move(to: CGPoint(x: r.minX + 1.52866483 * radius, y: r.minY))
    path.addLine(to: CGPoint(x: r.maxX - 1.52866483 * radius, y: r.minY))
    corner(CGPoint(x: r.maxX, y: r.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1))
    corner(CGPoint(x: r.maxX, y: r.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0))
    corner(CGPoint(x: r.minX, y: r.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1))
    corner(CGPoint(x: r.minX, y: r.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0))
    path.closeSubpath()
    return path
}

func draw(_ ctx: CGContext, pixels: Int) {
    let k = CGFloat(pixels) / grid // shadows are drawn in device space, so scale them by hand
    ctx.scaleBy(x: k, y: k)

    // Body: 824 pt rounded square on the 100 pt inset, soft drop shadow, vertical blue gradient.
    let body = shape(CGRect(x: 100, y: 100, width: 824, height: 824), radius: 185.4)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 20 * k, color: rgb(0, 0, 0, 0.30))
    ctx.addPath(body)
    ctx.setFillColor(rgb(30, 90, 200))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let fill = CGGradient(colorsSpace: space, colors: [rgb(64, 146, 245), rgb(28, 74, 186)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // The scope, centred on the body: a ring, four ticks outside it, and a centre dot.
    let c = CGPoint(x: 512, y: 512), white = rgb(255, 255, 255)
    ctx.setStrokeColor(white)
    ctx.setLineCap(.round)
    ctx.setLineWidth(52)
    ctx.addArc(center: c, radius: 200, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.strokePath()
    ctx.setLineWidth(44)
    for angle in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 2) {
        let (s, e) = (CGFloat(cos(angle)), CGFloat(sin(angle)))
        ctx.move(to: CGPoint(x: c.x + 262 * s, y: c.y + 262 * e))
        ctx.addLine(to: CGPoint(x: c.x + 336 * s, y: c.y + 336 * e))
        ctx.strokePath()
    }
    ctx.setFillColor(white)
    ctx.fillEllipse(in: CGRect(x: c.x - 56, y: c.y - 56, width: 112, height: 112))
}

func writePNG(pixels: Int, dpi: CGFloat, to url: URL) {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    draw(ctx, pixels: pixels)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    let props = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
    CGImageDestinationAddImage(dest, ctx.makeImage()!, props)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <out.iconset>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        writePNG(pixels: size * scale, dpi: CGFloat(72 * scale), to: out.appendingPathComponent(name))
    }
}
