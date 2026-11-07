import AppKit

// Generates the DMG installer background (660×400 pt, 1× and 2×).
// The design mirrors the app icon: deep-space dark navy, blue pulse rings,
// left icon zone / right Applications drop zone, and a drag arrow in between.

func generateDMGBackground(scale: CGFloat, outputPath: String) {
    let ptWidth: CGFloat  = 660
    let ptHeight: CGFloat = 400
    let pxWidth  = Int(ptWidth  * scale)
    let pxHeight = Int(ptHeight * scale)

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pxWidth,
        pixelsHigh: pxHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: pxWidth * 4,
        bitsPerPixel: 32
    )!
    rep.size = NSSize(width: ptWidth, height: ptHeight)

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Failed to create NSGraphicsContext")
    }
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // Work in top-left (0,0) coordinate space.
    cg.translateBy(x: 0, y: ptHeight)
    cg.scaleBy(x: 1.0, y: -1.0)

    func srgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed:   CGFloat((hex >> 16) & 0xFF) / 255,
            green:     CGFloat((hex >>  8) & 0xFF) / 255,
            blue:      CGFloat( hex        & 0xFF) / 255,
            alpha:     a
        )
    }
    func cgColor(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        srgb(hex, a).cgColor
    }

    // ── 1. Deep-space radial background ───────────────────────────────────
    let bgCenter = CGPoint(x: ptWidth / 2, y: ptHeight / 2)
    let bgGradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [cgColor(0x1a2a4a), cgColor(0x060d1a)] as CFArray,
        locations: [0.0, 1.0]
    )!
    cg.drawRadialGradient(
        bgGradient,
        startCenter: bgCenter, startRadius: 0,
        endCenter:   bgCenter, endRadius: 460,
        options: [.drawsAfterEndLocation]
    )

    // ── 2. Subtle star-field noise (fine dot grid for texture) ────────────
    cg.saveGState()
    srgb(0xffffff, 0.07).setFill()
    // A deterministic pseudo-random scatter using LCG values baked in.
    let starSeeds: [(CGFloat, CGFloat)] = [
        (38,22),(90,310),(150,55),(200,370),(280,130),(320,290),(400,45),(460,330),
        (510,180),(580,80),(620,350),(30,250),(100,165),(170,290),(240,20),(350,380),
        (430,110),(495,255),(555,30),(625,200),(70,350),(140,100),(210,215),(300,160),
        (380,320),(450,70),(530,275),(600,140),(45,120),(260,340),(490,20),(645,300),
    ]
    for (sx, sy) in starSeeds {
        let r: CGFloat = (Int(sx * 7 + sy * 13) % 3 == 0) ? 1.5 : 1.0
        cg.fillEllipse(in: CGRect(x: sx - r/2, y: sy - r/2, width: r, height: r))
    }
    cg.restoreGState()

    // ── 3. Large decorative pulse rings centred on the canvas ─────────────
    let rc = CGPoint(x: ptWidth / 2, y: ptHeight / 2)
    let ringSpecs: [(CGFloat, UInt32, CGFloat)] = [
        (220, 0x1a3870, 1.0),
        (186, 0x274e9e, 1.5),
        (152, 0x3d6bbf, 1.5),
    ]
    for (r, hex, lw) in ringSpecs {
        let ring = NSBezierPath(
            ovalIn: CGRect(x: rc.x - r, y: rc.y - r, width: r*2, height: r*2)
        )
        ring.lineWidth = lw
        srgb(hex).setStroke()
        ring.stroke()
    }

    // ── 4. Left drop-zone ghost circle (app icon landing pad) ─────────────
    let leftZone  = CGPoint(x: 180, y: ptHeight / 2)
    let rightZone = CGPoint(x: 480, y: ptHeight / 2)
    let zoneR: CGFloat = 72

    for zone in [leftZone, rightZone] {
        let pad = NSBezierPath(
            ovalIn: CGRect(x: zone.x - zoneR, y: zone.y - zoneR, width: zoneR*2, height: zoneR*2)
        )
        pad.lineWidth = 1.0
        srgb(0x3d6bbf, 0.25).setStroke()
        // dashed
        let dashPat: [CGFloat] = [5, 4]
        pad.setLineDash(dashPat, count: 2, phase: 0)
        pad.stroke()
    }

    // ── 5. Arrow capsule between the two zones ────────────────────────────
    let yCenter: CGFloat = ptHeight / 2
    let pillX: CGFloat   = ptWidth / 2
    let pillRect = CGRect(x: pillX - 30, y: yCenter - 19, width: 60, height: 38)
    let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 19, yRadius: 19)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 2), blur: 14, color: cgColor(0x4a80f0, 0.35))
    // Dark glass pill
    srgb(0x0d1f40, 0.85).setFill()
    pillPath.fill()
    cg.restoreGState()
    // Pill border
    srgb(0x3d6bbf, 0.6).setStroke()
    pillPath.lineWidth = 1.0
    pillPath.stroke()

    // Arrow chevron
    let arrow = NSBezierPath()
    arrow.move(to:    CGPoint(x: pillX - 11, y: yCenter))
    arrow.line(to:    CGPoint(x: pillX +  9, y: yCenter))
    arrow.move(to:    CGPoint(x: pillX +  2, y: yCenter - 6))
    arrow.line(to:    CGPoint(x: pillX +  9, y: yCenter))
    arrow.line(to:    CGPoint(x: pillX +  2, y: yCenter + 6))
    arrow.lineWidth    = 2.5
    arrow.lineCapStyle  = .round
    arrow.lineJoinStyle = .round
    srgb(0x8eb0f7).setStroke()
    arrow.stroke()

    // Dashed track lines flanking the capsule
    let trackY = yCenter
    for (x0, x1) in [(CGFloat(260), CGFloat(300)), (CGFloat(360), CGFloat(400))] {
        let track = NSBezierPath()
        track.move(to:  CGPoint(x: x0, y: trackY))
        track.line(to:  CGPoint(x: x1, y: trackY))
        track.setLineDash([3, 4], count: 2, phase: 0)
        track.lineWidth = 1.0
        srgb(0x3d6bbf, 0.4).setStroke()
        track.stroke()
    }

    // ── 6. Typography (flip back to normal for text) ───────────────────────
    cg.translateBy(x: 0, y: ptHeight)
    cg.scaleBy(x: 1.0, y: -1.0)

    let pStyle       = NSMutableParagraphStyle()
    pStyle.alignment = .center

    let labelAttrs: [NSAttributedString.Key: Any] = [
        .font:            NSFont.systemFont(ofSize: 10, weight: .semibold),
        .foregroundColor: srgb(0x8eb0f7, 0.75),
        .paragraphStyle:  pStyle,
        .kern:            1.8,
    ]
    // "DRAG TO INSTALL" label centred between zones (just above the arrow pill)
    NSAttributedString(string: "DRAG TO INSTALL", attributes: labelAttrs)
        .draw(in: CGRect(x: 180, y: ptHeight - (yCenter - 38), width: 300, height: 18))

    // App name below left zone
    let appAttrs: [NSAttributedString.Key: Any] = [
        .font:            NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: srgb(0xd0deff, 0.6),
        .paragraphStyle:  pStyle,
    ]
    NSAttributedString(string: "KapKap", attributes: appAttrs)
        .draw(in: CGRect(x: 110, y: ptHeight - (yCenter + zoneR + 20), width: 140, height: 18))

    // "Applications" label below right zone
    NSAttributedString(string: "Applications", attributes: appAttrs)
        .draw(in: CGRect(x: 410, y: ptHeight - (yCenter + zoneR + 20), width: 140, height: 18))

    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to convert image to PNG")
    }
    try! pngData.write(to: URL(fileURLWithPath: outputPath))
    print("Generated: \(outputPath) (\(pxWidth)x\(pxHeight))")
}

generateDMGBackground(scale: 1.0, outputPath: "Resources/dmg_background.png")
generateDMGBackground(scale: 2.0, outputPath: "Resources/dmg_background@2x.png")
