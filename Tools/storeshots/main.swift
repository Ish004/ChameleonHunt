//
//  storeshots — App Store screenshots and marketing pictures, in the game's own look.
//
//  storeshots frame <spec.txt> <outdir>
//      Each line of spec.txt:  image.png | Caption | tint (optional: natural, sun,
//      bubblegum, sky, tangerine, cherry)
//      Makes, for every line, a 6.9" iPhone picture (1320×2868) from phone screenshots
//      and a 13" iPad picture (2064×2752) from iPad ones — or the landscape versions
//      from landscape screenshots. The screenshot sits on the show's violet stage as a
//      sticker, under a big outlined caption, with the chameleon peeking over its edge.
//
//  storeshots crew <outdir>
//      The chameleon in all six squad colours (transparent PNGs) and a line-up picture,
//      for the website and social posts.
//
//  Built by Tools/build.sh with the game's Core sources (the chameleon is drawn by the
//  game's own MascotRenderer), so it runs on any Mac without Xcode's simulators.
//

import AppKit
import CoreText
import Foundation

// MARK: - The look

struct RGB { let r, g, b: CGFloat
    init(_ hex: Int) { r = CGFloat((hex >> 16) & 255) / 255; g = CGFloat((hex >> 8) & 255) / 255; b = CGFloat(hex & 255) / 255 }
    var cg: CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }
    func cg(_ alpha: CGFloat) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: alpha) }
    var ns: NSColor { NSColor(red: r, green: g, blue: b, alpha: 1) }
}
let stageTop = RGB(0x7D4FFF), stage = RGB(0x5A2EE2), stageBottom = RGB(0x3A1AA4), ink = RGB(0x1A0B3B)

/// The same tints as the game (UI/Mascot.swift, MascotTint).
func palette(_ tint: String) -> MascotRenderer.Palette {
    func camo(_ c: Vec3) -> MascotRenderer.Palette {
        var p = MascotRenderer.Palette(); p.body = c; p.back = c * 0.86; p.belly = c + (Vec3(repeating: 1) - c) * 0.3; return p
    }
    switch tint {
    case "sun": return camo([1.0, 0.824, 0.247])
    case "bubblegum": return camo([1.0, 0.31, 0.65])
    case "sky": return camo([0.247, 0.816, 0.957])
    case "tangerine": return camo([1.0, 0.541, 0.239])
    case "cherry": return camo([1.0, 0.337, 0.337])
    default: return MascotRenderer.Palette()
    }
}
let tints = ["natural", "sun", "bubblegum", "sky", "tangerine", "cherry"]

// The game's lettering, from the project's own font file.
let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let fontURL = projectRoot.appendingPathComponent("ChameleonHunt/Fonts/LilitaOne-Regular.ttf")
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
func lilita(_ size: CGFloat) -> NSFont { NSFont(name: "LilitaOne", size: size) ?? .systemFont(ofSize: size, weight: .black) }
func rounded(_ size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .bold)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

// MARK: - Drawing

/// A top-down drawing context of `size` pixels, and a PNG of what's drawn.
func draw(_ size: CGSize, _ body: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    // Text and images drawn through AppKit need to know it's flipped.
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    body(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ path: String, opaque: Bool = false) {
    var out = rep
    if opaque, let image = rep.cgImage,
       let flat = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
        // The App Store wants screenshots without an alpha channel.
        flat.draw(image, in: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        if let made = flat.makeImage() { out = NSBitmapImageRep(cgImage: made) }
    }
    try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
}

/// The stage: violet top to bottom, and nine soft rays turning out of `focus`.
func stageBackground(_ cg: CGContext, _ size: CGSize, focus: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [stageTop.cg, stage.cg, stageBottom.cg] as CFArray, locations: [0, 0.5, 1])!
    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
    let reach = hypot(size.width, size.height)
    cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
    for i in 0..<9 {
        let a = CGFloat(i) / 9 * 2 * .pi + 0.2
        let spread = 2 * .pi / 9 * 0.42
        cg.move(to: focus)
        cg.addLine(to: CGPoint(x: focus.x + cos(a - spread / 2) * reach, y: focus.y + sin(a - spread / 2) * reach))
        cg.addLine(to: CGPoint(x: focus.x + cos(a + spread / 2) * reach, y: focus.y + sin(a + spread / 2) * reach))
        cg.closePath()
        cg.fillPath()
    }
    // A soft glow where the rays meet.
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.16), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    cg.drawRadialGradient(glow, startCenter: focus, startRadius: 0, endCenter: focus, endRadius: size.width * 0.55, options: [])
}

/// One line of lettering as a path, starting at x = 0 on the baseline.
func linePath(_ text: String, font: CTFont) -> (path: CGPath, width: CGFloat) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        for k in 0..<count {
            guard let glyph = CTFontCreatePathForGlyph(font, glyphs[k], nil) else { continue }
            // Glyphs are drawn y-up; the canvas is y-down.
            var t = CGAffineTransform(translationX: positions[k].x, y: 0).scaledBy(x: 1, y: -1)
            path.addPath(glyph, transform: t)
            _ = t
        }
    }
    return (path, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
}

/// Outlined show lettering like the game's ShowText — an ink outline with round corners,
/// an ink drop under it, the letters on top — centred in `box`, wrapping onto more lines
/// when it doesn't fit. Returns the height used.
@discardableResult
func showText(_ text: String, in box: CGRect, size: CGFloat, fill: NSColor = .white) -> CGFloat {
    guard let cg = NSGraphicsContext.current?.cgContext else { return 0 }
    let font = CTFontCreateWithName("LilitaOne" as CFString, size, nil)
    let outline = max(3, size * 0.075)
    // Wrap by words to the box width (leaving room for the outline), then again to an
    // even width, so a caption doesn't leave one word on its own line.
    let words = text.uppercased().split(separator: " ").map(String.init)
    func wrap(_ limit: CGFloat) -> [String] {
        var lines: [String] = []
        for word in words {
            if let last = lines.last, linePath(last + " " + word, font: font).width <= limit {
                lines[lines.count - 1] = last + " " + word
            } else {
                lines.append(word)
            }
        }
        return lines
    }
    var lines = wrap(box.width - outline * 2)
    if lines.count > 1 {
        let total = linePath(words.joined(separator: " "), font: font).width
        let even = wrap(max(total / CGFloat(lines.count) * 1.12, 1))
        if even.count == lines.count { lines = even }
    }
    let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
    let lineHeight = (ascent + descent) * 0.92
    for (n, line) in lines.enumerated() {
        let (path, width) = linePath(line, font: font)
        let origin = CGPoint(x: box.midX - width / 2, y: box.minY + outline + ascent + CGFloat(n) * lineHeight)
        var move = CGAffineTransform(translationX: origin.x, y: origin.y)
        guard let placed = path.copy(using: &move) else { continue }
        cg.saveGState()
        cg.setLineJoin(.round)
        cg.setLineCap(.round)
        cg.setLineWidth(outline * 2)
        cg.setStrokeColor(ink.cg)
        cg.setFillColor(ink.cg)
        // The drop, then the outline, then the letters.
        cg.saveGState(); cg.translateBy(x: 0, y: outline); cg.addPath(placed); cg.drawPath(using: .fillStroke); cg.restoreGState()
        cg.addPath(placed); cg.strokePath()
        cg.setFillColor(fill.cgColor)
        cg.addPath(placed); cg.fillPath()
        cg.restoreGState()
    }
    return CGFloat(lines.count) * lineHeight + outline * 3 + descent * 0.3
}

/// A sticker: the image with rounded corners, a thick ink edge and a hard ink shadow.
func sticker(_ cg: CGContext, _ image: NSImage, in rect: CGRect, radius: CGFloat, edge: CGFloat) {
    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    cg.addPath(CGPath(roundedRect: rect.offsetBy(dx: 0, dy: edge * 2.2), cornerWidth: radius, cornerHeight: radius, transform: nil))
    cg.setFillColor(ink.cg)
    cg.fillPath()
    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    cg.restoreGState()
    cg.addPath(shape)
    cg.setStrokeColor(ink.cg)
    cg.setLineWidth(edge)
    cg.strokePath()
}

/// The chameleon as a picture, from the game's own renderer (in greys, for the tinted icon).
func chameleon(_ tint: String, size: Int, pose: CharacterPose = .standing, greys: Bool = false) -> NSImage {
    var image = MascotRenderer.render(pose, view: .hero, size: size, palette: palette(tint))
    if greys {
        for i in stride(from: 0, to: image.pixels.count, by: 4) {
            let y = 0.299 * Double(image.pixels[i]) + 0.587 * Double(image.pixels[i + 1]) + 0.114 * Double(image.pixels[i + 2])
            let v = UInt8(min(255, y.rounded()))
            image.pixels[i] = v; image.pixels[i + 1] = v; image.pixels[i + 2] = v
        }
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: image.width * 4, bitsPerPixel: 32)!
    image.pixels.withUnsafeBytes { raw in
        rep.bitmapData!.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: image.pixels.count)
    }
    let out = NSImage(size: NSSize(width: image.width, height: image.height))
    out.addRepresentation(rep)
    return out
}

// MARK: - Commands

func frame(spec: String, outDir: String) {
    let lines = (try? String(contentsOfFile: spec, encoding: .utf8))?.split(separator: "\n") ?? []
    let specDir = URL(fileURLWithPath: spec).deletingLastPathComponent()
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    var index = -1
    for line in lines {
        let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, !parts[0].hasPrefix("#") else { continue }
        index += 1
        let url = parts[0].hasPrefix("/") ? URL(fileURLWithPath: parts[0]) : specDir.appendingPathComponent(parts[0])
        guard let shot = NSImage(contentsOf: url), let rep = shot.representations.first else {
            print("can't read \(url.path)"); continue
        }
        let pixels = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        let landscape = pixels.width > pixels.height
        // A phone screen is tall and thin (about 2.2:1); an iPad's about 4:3.
        let isPhone = max(pixels.width, pixels.height) / min(pixels.width, pixels.height) > 1.7
        let portraitSize = isPhone ? CGSize(width: 1320, height: 2868) : CGSize(width: 2064, height: 2752)
        let size = landscape ? CGSize(width: portraitSize.height, height: portraitSize.width) : portraitSize
        let tint = parts.count > 2 ? parts[2] : tints[index % tints.count]

        let picture = draw(size) { cg in
            stageBackground(cg, size, focus: CGPoint(x: size.width / 2, y: size.height * 0.6))
            let margin = size.width * 0.07
            let captionSize = (landscape ? size.height : size.width) * (isPhone ? 0.092 : 0.075)
            let used = showText(parts[1], in: CGRect(x: margin, y: size.height * 0.045, width: size.width - margin * 2, height: size.height * 0.3),
                                size: captionSize)
            // The screenshot, as big as fits under the caption.
            let top = size.height * 0.045 + used + size.height * 0.035
            let room = CGSize(width: size.width - margin * 2, height: size.height - top - size.height * 0.05)
            let scale = min(room.width / pixels.width, room.height / pixels.height)
            let shotSize = CGSize(width: pixels.width * scale, height: pixels.height * scale)
            let rect = CGRect(x: (size.width - shotSize.width) / 2, y: top, width: shotSize.width, height: shotSize.height)
            let edge = max(6, size.width * 0.009)
            sticker(cg, shot, in: rect, radius: min(shotSize.width, shotSize.height) * (isPhone ? 0.09 : 0.045), edge: edge)
            // The chameleon peeking over the bottom corner.
            let side = min(size.width, size.height) * (isPhone ? 0.3 : 0.2)
            let mascot = chameleon(tint, size: Int(side))
            // Over the corner, but never off the picture.
            let y = min(rect.maxY - side * 0.62, size.height - side * 0.92)
            let x = min(rect.maxX - side * 0.78, size.width - side * 0.98)
            mascot.draw(in: CGRect(x: x, y: y, width: side, height: side),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let name = String(format: "%02d-%@-%@.png", index + 1, isPhone ? "iphone" : "ipad", landscape ? "landscape" : "portrait")
        save(picture, "\(outDir)/\(name)", opaque: true)
    }
}

func crew(outDir: String) {
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    var images: [NSImage] = []
    for tint in tints {
        let image = chameleon(tint, size: 720)
        images.append(image)
        let rep = draw(CGSize(width: 720, height: 720)) { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: 720, height: 720), from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
        }
        save(rep, "\(outDir)/chameleon-\(tint).png")
    }
    // The line-up, on the stage: a banner for the website and social posts.
    let size = CGSize(width: 2400, height: 1260)
    let banner = draw(size) { cg in
        stageBackground(cg, size, focus: CGPoint(x: size.width / 2, y: size.height * 0.7))
        showText("Chameleon Hunt", in: CGRect(x: 0, y: size.height * 0.08, width: size.width, height: 300), size: 190)
        showText("Hide and seek in your real room", in: CGRect(x: 0, y: size.height * 0.3, width: size.width, height: 120),
                 size: 72, fill: NSColor(red: 0.55, green: 0.88, blue: 0.29, alpha: 1))
        let side: CGFloat = 360
        let gap: CGFloat = 20
        let total = CGFloat(images.count) * side + CGFloat(images.count - 1) * gap
        for (i, image) in images.enumerated() {
            let x = (size.width - total) / 2 + CGFloat(i) * (side + gap)
            let lift: CGFloat = i % 2 == 0 ? 0 : -30
            image.draw(in: CGRect(x: x, y: size.height * 0.5 + lift, width: side, height: side), from: .zero,
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
    save(banner, "\(outDir)/crew-banner.png", opaque: true)
}

/// The app icon's dark and tinted versions (iOS 18 and later let people choose): the
/// chameleon alone on a transparent square — the system draws the dark background or the
/// tint — in its own colours for dark, in greys for tinted.
func icons(outDir: String) {
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let size = CGSize(width: 1024, height: 1024)
    let figure = chameleon("natural", size: 900)
    let place = CGRect(x: 62, y: 62 + 30, width: 900, height: 900)
    let dark = draw(size) { _ in
        figure.draw(in: place, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    save(dark, "\(outDir)/AppIcon-Dark.png")
    // Greys only: the system tints it, keeping the shape and shading.
    let grey = chameleon("natural", size: 900, greys: true)
    let tinted = draw(size) { _ in
        grey.draw(in: place, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    save(tinted, "\(outDir)/AppIcon-Tinted.png")
}

/// The game's share picture (UI/ShareCard.swift) from any photo: the photo on top and a
/// violet strip underneath with the headline in the game's lettering and the chameleon.
/// For "Can you spot it?" posts made from a screenshot, and to check the in-game design.
func card(photoPath: String, headline: String, detail: String, out: String) {
    guard let photo = NSImage(contentsOfFile: photoPath), let rep = photo.representations.first else {
        print("can't read \(photoPath)"); return
    }
    let size0 = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    let band = max(140, min(size0.width, size0.height) * 0.28)
    let size = CGSize(width: size0.width, height: size0.height + band)
    let picture = draw(size) { cg in
        photo.draw(in: CGRect(origin: .zero, size: size0), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let strip = CGRect(x: 0, y: size0.height, width: size.width, height: band)
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [stageTop.cg, stageBottom.cg] as CFArray, locations: [0, 1])!
        cg.saveGState(); cg.clip(to: strip)
        cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: strip.minY), end: CGPoint(x: 0, y: strip.maxY), options: [])
        cg.restoreGState()
        cg.setFillColor(ink.cg)
        cg.fill(CGRect(x: 0, y: size0.height, width: size.width, height: max(4, band * 0.04)))
        let margin = band * 0.16
        let side = band * 0.86
        let mascot = chameleon("natural", size: Int(side))
        let mascotRect = CGRect(x: size.width - margin - side, y: strip.midY - side / 2 + band * 0.02, width: side, height: side)
        mascot.draw(in: mascotRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let textWidth = mascotRect.minX - margin * 1.5
        // One line, shrunk to fit, as the game does.
        let natural = linePath(headline.uppercased(), font: CTFontCreateWithName("LilitaOne" as CFString, band * 0.3, nil)).width
        let fitted = band * 0.3 * max(0.5, min(1, (textWidth - band * 0.06) / max(natural, 1)))
        let used = showText(headline, in: CGRect(x: margin - band * 0.02, y: strip.minY + band * 0.1, width: textWidth, height: band * 0.5),
                            size: fitted)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (detail as NSString).draw(in: CGRect(x: margin, y: strip.minY + band * 0.08 + used, width: textWidth, height: band * 0.34),
                                  withAttributes: [.font: rounded(band * 0.12), .foregroundColor: NSColor(white: 1, alpha: 0.85),
                                                   .paragraphStyle: paragraph])
    }
    save(picture, out, opaque: true)
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "card" where args.count > 4:
    card(photoPath: args[2], headline: args[3], detail: args.count > 5 ? args[5] : "ChameleonHunt · hide and seek", out: args[4])
case "icons" where args.count > 2: icons(outDir: args[2])
case "frame" where args.count > 3: frame(spec: args[2], outDir: args[3])
case "crew" where args.count > 2: crew(outDir: args[2])
default:
    print("""
    storeshots frame <spec.txt> <outdir>   (spec lines: image.png | Caption | tint)
    storeshots crew <outdir>
    storeshots icons <outdir>
    storeshots card <photo.png> <headline> <out.png> [detail]
    """)
}
