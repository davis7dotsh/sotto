import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// The V07 ribbon icon, drawn directly with Core Graphics.
// Keep these normalized ribbon curves in sync with V07Brand.ribbonPath(in:).
func ribbonPath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 102, y: 18))
    path.addLine(to: CGPoint(x: 62, y: 18))
    path.addCurve(to: CGPoint(x: 22, y: 50), control1: CGPoint(x: 38, y: 18), control2: CGPoint(x: 22, y: 31))
    path.addCurve(to: CGPoint(x: 49, y: 81), control1: CGPoint(x: 22, y: 67), control2: CGPoint(x: 33, y: 76))
    path.addLine(to: CGPoint(x: 60, y: 59))
    path.addCurve(to: CGPoint(x: 47, y: 48), control1: CGPoint(x: 50, y: 56), control2: CGPoint(x: 47, y: 53))
    path.addCurve(to: CGPoint(x: 63, y: 40), control1: CGPoint(x: 47, y: 43), control2: CGPoint(x: 53, y: 40))
    path.addLine(to: CGPoint(x: 102, y: 40))
    path.closeSubpath()
    path.move(to: CGPoint(x: 26, y: 110))
    path.addLine(to: CGPoint(x: 66, y: 110))
    path.addCurve(to: CGPoint(x: 106, y: 78), control1: CGPoint(x: 90, y: 110), control2: CGPoint(x: 106, y: 97))
    path.addCurve(to: CGPoint(x: 79, y: 47), control1: CGPoint(x: 106, y: 61), control2: CGPoint(x: 95, y: 52))
    path.addLine(to: CGPoint(x: 68, y: 69))
    path.addCurve(to: CGPoint(x: 81, y: 80), control1: CGPoint(x: 78, y: 72), control2: CGPoint(x: 81, y: 75))
    path.addCurve(to: CGPoint(x: 65, y: 88), control1: CGPoint(x: 81, y: 85), control2: CGPoint(x: 75, y: 88))
    path.addLine(to: CGPoint(x: 26, y: 88))
    path.closeSubpath()
    return path
}

func color(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha).cgColor
}

func makeIcon(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    let graphics = context.cgContext
    graphics.translateBy(x: 0, y: CGFloat(pixels))
    graphics.scaleBy(x: CGFloat(pixels) / 512, y: -CGFloat(pixels) / 512)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let background = CGPath(roundedRect: CGRect(x: 12, y: 12, width: 488, height: 488),
                            cornerWidth: 112, cornerHeight: 112, transform: nil)
    let paper = CGGradient(colorsSpace: colorSpace, colors: [color(0xFCF9F2), color(0xE8D9D4)] as CFArray,
                           locations: [0, 1])!
    graphics.saveGState()
    graphics.addPath(background)
    graphics.clip()
    graphics.drawLinearGradient(paper, start: CGPoint(x: 80, y: 20), end: CGPoint(x: 420, y: 500),
                                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    graphics.restoreGState()

    let edge = CGPath(roundedRect: CGRect(x: 13, y: 13, width: 486, height: 486),
                      cornerWidth: 111, cornerHeight: 111, transform: nil)
    let edgeGradient = CGGradient(colorsSpace: colorSpace,
                                  colors: [color(0xFFFFFF, alpha: 0.9), color(0x352D3A, alpha: 0.12)] as CFArray,
                                  locations: [0, 1])!
    graphics.saveGState()
    graphics.addPath(edge)
    graphics.setLineWidth(2)
    graphics.replacePathWithStrokedPath()
    graphics.clip()
    graphics.drawLinearGradient(edgeGradient, start: CGPoint(x: 180, y: 0), end: CGPoint(x: 300, y: 512),
                                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    graphics.restoreGState()

    graphics.translateBy(x: 83, y: 83)
    graphics.scaleBy(x: 2.7, y: 2.7)
    graphics.setFillColor(color(0x352D3A))
    graphics.addPath(ribbonPath())
    graphics.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try makeIcon(pixels: size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try makeIcon(pixels: size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
