#!/usr/bin/env swift
// Draws Prompter's art: rough text lines tidied into a prompt, with a lime spark.
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

/// A four-point spark centred on `c`.
func spark(_ ctx: CGContext, at c: CGPoint, radius r: CGFloat, color: CGColor) {
    let w = r * 0.26
    let path = CGMutablePath()
    path.move(to: CGPoint(x: c.x, y: c.y + r))
    path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y + w))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + w, y: c.y - w))
    path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y - w))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - w, y: c.y + w))
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

func bar(_ ctx: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, color: CGColor) {
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height),
                       cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
    ctx.setFillColor(color)
    ctx.fillPath()
}

// MARK: - App icon

func iconImage() -> CGImage {
    // macOS icon grid: an 824 px rounded square centred on a 1024 canvas, drawn here because macOS 14 doesn't mask it.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let ctx = context(1024, 1024)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(ink)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [rgb(0.17, 0.17, 0.19), rgb(0.06, 0.06, 0.07)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Three lines of a prompt: two settled white lines, the last one lime because it was just rewritten.
    bar(ctx, x: 236, y: 560, width: 420, height: 64, color: rgb(1, 1, 1, 0.92))
    bar(ctx, x: 236, y: 452, width: 330, height: 64, color: rgb(1, 1, 1, 0.55))
    bar(ctx, x: 236, y: 344, width: 230, height: 64, color: lime)
    // Text caret after the last line.
    bar(ctx, x: 500, y: 320, width: 22, height: 112, color: lime)
    spark(ctx, at: CGPoint(x: 726, y: 700), radius: 112, color: lime)
    spark(ctx, at: CGPoint(x: 806, y: 556), radius: 46, color: rgb(0.80, 0.96, 0.40, 0.7))
    ctx.restoreGState()

    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.10))
    ctx.setLineWidth(3)
    ctx.strokePath()
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
