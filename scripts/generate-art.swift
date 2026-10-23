#!/usr/bin/env swift
// Draws Prompter's art: a glowing lime `>_` prompt, and the DMG window background.
//
//   swift scripts/generate-art.swift
//       writes the app icon, at every size, into the asset catalog.
//   swift scripts/generate-art.swift dmg-background <out-dir> <width> <height> <app-x> <apps-x> <icon-y>
//       writes the DMG window background as background.png and background@2x.png.
//       Coordinates are Finder's: points, origin top-left, positions are icon centres.
import AppKit

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// Same values as Brand in Prompter/Onboarding.swift.
let ink = rgb(0.067, 0.067, 0.075)
let lime = rgb(0.80, 0.96, 0.40)

func context(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - App icon

/// macOS's continuous-corner icon shape: a superellipse (n = 5) filling 80% of the canvas, in 0–100 units.
func squircle() -> CGPath {
    let path = CGMutablePath()
    for i in 0...144 {
        let t = Double(i) / 144 * 2 * .pi, c = cos(t), s = sin(t)
        let p = CGPoint(x: 50 + 40 * (c < 0 ? -1 : 1) * pow(abs(c), 0.4), y: 50 + 40 * (s < 0 ? -1 : 1) * pow(abs(s), 0.4))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// "Phosphor": a lime `>_` prompt glowing like an old terminal, on near-black with faint scanlines.
func iconImage() -> CGImage {
    let ctx = context(1024, 1024)
    // Draw in 0–100 units with y pointing down, like the SVG mockup. Shadow offsets ignore this transform.
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 10.24, y: -10.24)
    let shape = squircle()
    let top = CGPoint(x: 50, y: 10), bottom = CGPoint(x: 50, y: 90)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(ink)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0.086, 0.094, 0.102)), (1, rgb(0.02, 0.02, 0.024))]), start: top, end: bottom, options: [])
    ctx.setStrokeColor(rgb(0.80, 0.96, 0.40, 0.02))
    ctx.setLineWidth(1)
    for y in stride(from: 30, through: 78, by: 12) {
        ctx.move(to: CGPoint(x: 20, y: y))
        ctx.addLine(to: CGPoint(x: 80, y: y))
    }
    ctx.strokePath()

    // The prompt, drawn four times: three glow passes, then the crisp shape on top.
    let glyph = CGMutablePath()
    glyph.move(to: CGPoint(x: 29.5, y: 35.5))
    glyph.addLine(to: CGPoint(x: 44.5, y: 50))
    glyph.addLine(to: CGPoint(x: 29.5, y: 64.5))
    let prompt = CGMutablePath()
    prompt.addPath(glyph.copy(strokingWithWidth: 7, lineCap: .round, lineJoin: .round, miterLimit: 10))
    prompt.addPath(CGPath(roundedRect: CGRect(x: 51, y: 59.5, width: 19, height: 6.5), cornerWidth: 3.25, cornerHeight: 3.25, transform: nil))
    for blur in [90, 44, 44, 0] as [CGFloat] {
        ctx.saveGState()
        if blur > 0 { ctx.setShadow(offset: .zero, blur: blur, color: lime) }
        ctx.addPath(prompt)
        ctx.setFillColor(lime)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Glassy top sheen.
    ctx.drawLinearGradient(gradient([(0, rgb(1, 1, 1, 0.16)), (0.45, rgb(1, 1, 1, 0))]), start: top, end: bottom, options: [])
    ctx.restoreGState()

    // Rim light: bright along the top edge, faint around the rest.
    ctx.saveGState()
    ctx.addPath(shape.copy(strokingWithWidth: 0.8, lineCap: .butt, lineJoin: .round, miterLimit: 10))
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(1, 1, 1, 0.35)), (0.5, rgb(1, 1, 1, 0.04)), (1, rgb(1, 1, 1, 0.10))]),
                           start: top, end: bottom, options: [])
    ctx.restoreGState()
    return ctx.makeImage()!
}

func writeIcon() throws {
    let set = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Prompter/Resources/Assets.xcassets/AppIcon.appiconset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    let master = iconImage()
    var images: [[String: String]] = []
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = points * scale
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            let ctx = context(px, px)
            ctx.interpolationQuality = .high
            ctx.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
            try writePNG(ctx.makeImage()!, to: set.appendingPathComponent(name))
            images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
        }
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: set.appendingPathComponent("Contents.json"))
    try #"{"info":{"author":"xcode","version":1}}"#.write(to: set.deletingLastPathComponent().appendingPathComponent("Contents.json"),
                                                         atomically: true, encoding: .utf8)
    print("Icon: \(set.path)")
}

// MARK: - DMG background

func writeDMGBackground(out: URL, width: CGFloat, height: CGFloat, appX: CGFloat, appsX: CGFloat, iconY: CGFloat) throws {
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for scale in [1, 2] as [CGFloat] {
        let ctx = context(Int(width * scale), Int(height * scale))
        ctx.scaleBy(x: scale, y: scale)
        // Light, because Finder draws icon labels in black on DMG backgrounds.
        ctx.setFillColor(rgb(0.975, 0.975, 0.968))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Soft lime glow behind the app icon.
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [rgb(0.80, 0.96, 0.40, 0.45), rgb(0.80, 0.96, 0.40, 0)] as CFArray, locations: [0, 1])!
        let y = height - iconY // CoreGraphics origin is bottom-left
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: appX, y: y), startRadius: 0,
                               endCenter: CGPoint(x: appX, y: y), endRadius: 150, options: [])

        // Dashed arrow from the app to Applications.
        let from = appX + 92, to = appsX - 92
        ctx.setStrokeColor(rgb(0.36, 0.48, 0.08))
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: [2, 10])
        ctx.move(to: CGPoint(x: from, y: y))
        ctx.addLine(to: CGPoint(x: to - 6, y: y))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.move(to: CGPoint(x: to - 16, y: y + 11))
        ctx.addLine(to: CGPoint(x: to, y: y))
        ctx.addLine(to: CGPoint(x: to - 16, y: y - 11))
        ctx.strokePath()

        let title = NSAttributedString(string: "Drag Prompter into Applications", attributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor(white: 0.08, alpha: 1)])
        let note = NSAttributedString(string: "Then open it. It lives in your menu bar.", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.42, alpha: 1)])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        title.draw(at: CGPoint(x: (width - title.size().width) / 2, y: height - 62))
        note.draw(at: CGPoint(x: (width - note.size().width) / 2, y: 44))
        NSGraphicsContext.restoreGraphicsState()

        try writePNG(ctx.makeImage()!, to: out.appendingPathComponent(scale == 1 ? "background.png" : "background@2x.png"))
    }
}

let args = CommandLine.arguments
if args.count > 1, args[1] == "dmg-background" {
    let n = args.dropFirst(3).compactMap { Double($0) }.map { CGFloat($0) }
    guard args.count == 8, n.count == 5 else {
        FileHandle.standardError.write("usage: generate-art.swift dmg-background <out-dir> <width> <height> <app-x> <apps-x> <icon-y>\n".data(using: .utf8)!)
        exit(64)
    }
    try writeDMGBackground(out: URL(fileURLWithPath: args[2]), width: n[0], height: n[1], appX: n[2], appsX: n[3], iconY: n[4])
} else {
    try writeIcon()
}
