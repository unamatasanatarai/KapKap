import AppKit

// Generates the app icon from Resources/k-pulse-icon.svg: three concentric pulse rings around a
// blue gradient disc with a "k" cut out of it. NSImage cannot load SVG on macOS 12, so the SVG's
// shapes are redrawn here in its own 240-unit coordinate space; keep the two in sync.
// Usage: swift scripts/generate_app_icon.swift <output-dir>
// Writes <output-dir>/AppIcon.png (512 px) and <output-dir>/AppIcon.icns.

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}

func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: pixels * 4,
        bitsPerPixel: 32
    )!
    NSGraphicsContext.saveGraphicsState()
    let nsContext = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = nsContext
    let ctx = nsContext.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // SVG viewBox 0 0 240 240 with a top-left origin.
    let scale = CGFloat(pixels) / 240
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)

    // macOS app icon: explicit rounded-rectangle background so the icon looks
    // correct everywhere (including Finder on Apple Silicon where transparent
    // icons get an ugly white/grey chip behind them).
    // Corner radius for a 240-unit canvas follows Apple's icon grid: ~52.5/240 ≈ 21.9%
    let cornerRadius: CGFloat = 52.5
    let bgRect = CGRect(x: 0, y: 0, width: 240, height: 240)
    let bgPath = CGMutablePath()
    bgPath.addRoundedRect(in: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius)
    ctx.addPath(bgPath)
    ctx.clip()

    // Deep-space radial background: dark navy core → near-black edge
    let bgGradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0x1a2a4a), color(0x060d1a)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        bgGradient,
        startCenter: CGPoint(x: 120, y: 120), startRadius: 0,
        endCenter:   CGPoint(x: 120, y: 120), endRadius: 150,
        options: [.drawsAfterEndLocation]
    )

    let center = CGPoint(x: 120, y: 120)
    func circle(_ r: CGFloat) -> CGRect {
        CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    // Subtle glow halo behind rings
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: color(0x6699ff))
    ctx.setStrokeColor(CGColor.init(gray: 0, alpha: 0))  // paint nothing — shadow only
    ctx.strokeEllipse(in: circle(104))
    ctx.restoreGState()

    // Pulse rings, outermost first (brighter against the dark bg).
    for (radius, stroke, width) in [(116, 0x2a4a7f, 1.5), (102, 0x3d6bbf, 2.0), (88, 0x5b8de0, 2.5)]
        as [(CGFloat, UInt32, CGFloat)] {
        ctx.setStrokeColor(color(stroke))
        ctx.setLineWidth(width)
        ctx.strokeEllipse(in: circle(radius))
    }

    // Core disc with the "k" knocked out (even-odd clip), filled with a top-to-bottom gradient.
    let core = circle(72)
    let k = CGMutablePath()
    let dx: CGFloat = -1.5
    let points: [(CGFloat, CGFloat)] = [
        (100, 98), (111, 98), (111, 117), (128, 98), (142, 98), (121, 121), (143, 142),
        (129, 142), (113, 124), (111, 126), (111, 142), (100, 142)
    ]
    k.addLines(between: points.map { CGPoint(x: $0.0 + dx, y: $0.1) })
    k.closeSubpath()

    ctx.saveGState()
    ctx.addEllipse(in: core)
    ctx.addPath(k)
    ctx.clip(using: .evenOdd)
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0xdce8ff), color(0x8eb0f7)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: core.minY), end: CGPoint(x: 0, y: core.maxY),
                           options: [])
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encode failed") }
    try! data.write(to: URL(fileURLWithPath: path))
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let fm = FileManager.default
let iconset = NSTemporaryDirectory() + "AppIcon-\(ProcessInfo.processInfo.processIdentifier).iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    writePNG(renderIcon(pixels: base), to: "\(iconset)/icon_\(base)x\(base).png")
    writePNG(renderIcon(pixels: base * 2), to: "\(iconset)/icon_\(base)x\(base)@2x.png")
}
writePNG(renderIcon(pixels: 512), to: "\(outDir)/AppIcon.png")

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(atPath: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(outDir)/AppIcon.png and \(outDir)/AppIcon.icns")
