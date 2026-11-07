//
//  storeshots — App Store screenshots and marketing pictures, in the game's own look.
//
//  storeshots frame <spec.txt> <outdir>
//      Each line of spec.txt:  image.png | First line / Second line | chameleon
//      The chameleon is a colour or a skin (natural, bubblegum, sky, tangerine, cherry,
//      tiger, zebra…), then optionally what it's doing: standing, peeking, lying, curled.
//      Makes, for every line, a 6.9" iPhone picture (1320×2868) from phone screenshots
//      and a 13" iPad picture (2064×2752) from iPad ones — or the landscape versions
//      from landscape screenshots. Every picture is the same: the caption in the game's
//      lettering (second line in the chameleon's colour), the screenshot inside a drawn
//      iPhone or iPad, the chameleon on top of it, all on the app icon's yellow. The
//      device and the lettering are the same size and in the same place in every picture
//      of a set, whatever the captions say.
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
import SwiftUI

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
    // Any skin from the shop, by its name there.
    default: return ChameleonSkin(rawValue: tint)?.palette ?? MascotRenderer.Palette()
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
func chameleon(_ tint: String, size: Int, pose: CharacterPose = .standing, view: MascotRenderer.View = .hero,
               shadow: Bool = true, greys: Bool = false) -> NSImage {
    var image = MascotRenderer.render(pose, view: view, size: size, palette: palette(tint), shadow: shadow)
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

// MARK: - Store pictures

/// A device as seen from the front, measured in its own points: the screen, the black
/// border under the glass, the metal band round that, and what sits on the edges.
struct Device {
    enum Side { case left, right, top }
    struct Control { let side: Side; let at: CGFloat; let length: CGFloat }   // shares of that edge

    var screen: CGSize              // upright
    var corner: CGFloat             // the screen's corner radius
    var glass: CGFloat
    var band: CGFloat
    var island: CGRect? = nil       // the Dynamic Island, in screen points
    var lens: CGPoint? = nil        // a front camera in the border, in screen points
    var buttons: [Control] = []
    var flush: [Control] = []       // controls that sit level with the band

    var border: CGFloat { glass + band }
    var size: CGSize { CGSize(width: screen.width + border * 2, height: screen.height + border * 2) }

    /// An iPhone 17 Pro. The island is where the Simulator draws it (it leaves it out of
    /// some screenshots, so the frame always draws its own).
    static let phone = Device(screen: CGSize(width: 402, height: 874), corner: 62, glass: 9, band: 7,
                              island: CGRect(x: 138.33, y: 14, width: 125.34, height: 36.67),
                              buttons: [Control(side: .left, at: 0.207, length: 0.043), Control(side: .left, at: 0.300, length: 0.073),
                                        Control(side: .left, at: 0.387, length: 0.073), Control(side: .right, at: 0.335, length: 0.107)],
                              flush: [Control(side: .right, at: 0.640, length: 0.105)])
    /// A 13" iPad Pro, with its camera on the long edge.
    static let pad = Device(screen: CGSize(width: 1032, height: 1376), corner: 30.5, glass: 39, band: 5,
                            lens: CGPoint(x: 1032 + 19.5, y: 688),
                            buttons: [Control(side: .top, at: 0.885, length: 0.062), Control(side: .right, at: 0.085, length: 0.040),
                                      Control(side: .right, at: 0.137, length: 0.040)])

    /// The same device with a screen of another shape (a bigger phone, an older iPad).
    func fitting(aspect: CGFloat) -> Device {
        var device = self
        let height = screen.width * aspect
        if let lens { device.lens = CGPoint(x: lens.x, y: lens.y / screen.height * height) }
        device.screen.height = height
        return device
    }
}

/// A rounded rectangle with the continuous corners Apple's screens and devices have.
func squircle(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

func gradient(_ colours: [RGB], _ stops: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours.map(\.cg) as CFArray, locations: stops)!
}

/// Draws `shot` inside `device`, whose body fills `rect` on the canvas. A sideways device
/// has its top to the left, as a phone turned to play.
func drawDevice(_ cg: CGContext, _ device: Device, shot: NSImage, in rect: CGRect, sideways: Bool, shadow: CGColor) {
    let scale = (sideways ? rect.height : rect.width) / device.size.width
    let place = sideways ? CGAffineTransform(a: 0, b: -scale, c: scale, d: 0, tx: rect.minX, ty: rect.maxY)
                         : CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: rect.minX, ty: rect.minY)
    let body = CGRect(origin: .zero, size: device.size)
    let screen = CGRect(x: device.border, y: device.border, width: device.screen.width, height: device.screen.height)
    let bodyPath = squircle(body, device.corner + device.border)

    cg.saveGState()
    cg.concatenate(place)

    // The shadow it casts on the backdrop: soft, and the backdrop's own colour, only deeper.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -rect.width * 0.03), blur: rect.width * 0.055, color: shadow)
    cg.addPath(bodyPath)
    cg.setFillColor(RGB(0x2B2A31).cg)
    cg.fillPath()
    cg.restoreGState()

    // Buttons stand a little proud of the band.
    let proud: CGFloat = device.band * 0.38
    func control(_ c: Device.Control, out: CGFloat) -> CGRect {
        switch c.side {
        case .left: return CGRect(x: -out, y: body.height * (c.at - c.length / 2), width: out + device.band * 0.6, height: body.height * c.length)
        case .right: return CGRect(x: body.maxX - device.band * 0.6, y: body.height * (c.at - c.length / 2), width: out + device.band * 0.6, height: body.height * c.length)
        case .top: return CGRect(x: body.width * (c.at - c.length / 2), y: -out, width: body.width * c.length, height: out + device.band * 0.6)
        }
    }
    for button in device.buttons {
        let r = control(button, out: proud)
        cg.addPath(CGPath(roundedRect: r, cornerWidth: proud * 0.55, cornerHeight: proud * 0.55, transform: nil))
        cg.setFillColor(RGB(0x3A3940).cg)
        cg.fillPath()
    }

    // The band: brushed graphite, lighter where the light catches the top.
    cg.saveGState()
    cg.addPath(bodyPath)
    cg.clip()
    cg.drawLinearGradient(gradient([RGB(0x77767F), RGB(0x4B4A52), RGB(0x33323A)], [0, 0.45, 1]),
                          start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])
    cg.restoreGState()
    // Its outer edge, and the bright line where it turns toward the glass.
    cg.addPath(squircle(body.insetBy(dx: 0.35, dy: 0.35), device.corner + device.border - 0.35))
    cg.setStrokeColor(RGB(0x1B1A20).cg(0.75))
    cg.setLineWidth(0.7)
    cg.strokePath()
    let turn = device.band * 0.62
    cg.addPath(squircle(body.insetBy(dx: turn, dy: turn), device.corner + device.border - turn))
    cg.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    cg.setLineWidth(max(0.5, device.band * 0.09))
    cg.strokePath()
    for inset in device.flush {
        let r = control(inset, out: 0).insetBy(dx: device.band * 0.1, dy: 0)
        cg.addPath(CGPath(roundedRect: CGRect(x: body.maxX - device.band * 0.5, y: r.minY, width: device.band * 0.34, height: r.height),
                          cornerWidth: device.band * 0.17, cornerHeight: device.band * 0.17, transform: nil))
        cg.setFillColor(RGB(0x24232A).cg(0.9))
        cg.fillPath()
    }

    // The glass, and the screen under it.
    cg.addPath(squircle(body.insetBy(dx: device.band, dy: device.band), device.corner + device.glass))
    cg.setFillColor(RGB(0x07060A).cg)
    cg.fillPath()
    cg.saveGState()
    cg.addPath(squircle(screen, device.corner))
    cg.clip()
    cg.concatenate(place.inverted())
    shot.draw(in: screen.applying(place), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    cg.restoreGState()

    if let island = device.island?.offsetBy(dx: screen.minX, dy: screen.minY) {
        cg.addPath(CGPath(roundedRect: island, cornerWidth: island.height / 2, cornerHeight: island.height / 2, transform: nil))
        cg.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        cg.fillPath()
        drawLens(cg, at: CGPoint(x: island.maxX - island.height / 2, y: island.midY), radius: island.height * 0.17)
    }
    if let lens = device.lens {
        drawLens(cg, at: CGPoint(x: lens.x + screen.minX, y: lens.y + screen.minY), radius: device.glass * 0.1)
    }
    cg.restoreGState()
}

/// A camera behind the glass: nearly black, with the faintest ring.
func drawLens(_ cg: CGContext, at centre: CGPoint, radius: CGFloat) {
    func disc(_ r: CGFloat, _ colour: CGColor) {
        cg.setFillColor(colour)
        cg.fillEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
    }
    disc(radius, RGB(0x14141C).cg)
    disc(radius * 0.58, RGB(0x0A0A12).cg)
    disc(radius * 0.2, RGB(0x2D3058).cg(0.9))
}

/// A caption in the show's lettering, a colour to each line, centred on `centre` and
/// tipped a little like the game's own titles.
func drawCaption(_ cg: CGContext, _ lines: [(text: String, fill: RGB)], centre: CGPoint, size: CGFloat, tilt: CGFloat) {
    let font = CTFontCreateWithName("LilitaOne" as CFString, size, nil)
    let outline = captionOutline(size)
    let cap = CTFontGetCapHeight(font)
    let advance = size * captionAdvance
    let height = cap + CGFloat(lines.count - 1) * advance
    cg.saveGState()
    cg.translateBy(x: centre.x, y: centre.y)
    cg.rotate(by: tilt)
    cg.setLineJoin(.round)
    cg.setLineCap(.round)
    cg.setLineWidth(outline * 2)
    for (n, line) in lines.enumerated() {
        let (path, width) = linePath(line.text.uppercased(), font: font)
        var move = CGAffineTransform(translationX: -width / 2, y: -height / 2 + cap + CGFloat(n) * advance)
        guard let placed = path.copy(using: &move) else { continue }
        cg.setStrokeColor(ink.cg)
        cg.setFillColor(ink.cg)
        cg.saveGState(); cg.translateBy(x: 0, y: outline * 1.1); cg.addPath(placed); cg.drawPath(using: .fillStroke); cg.restoreGState()
        cg.addPath(placed); cg.strokePath()
        cg.setFillColor(line.fill.cg)
        cg.addPath(placed); cg.fillPath()
    }
    cg.restoreGState()
}

func captionOutline(_ size: CGFloat) -> CGFloat { max(3, size * 0.075) }
/// From one line of a caption to the next, as a share of the lettering's size: close, so
/// the lower line's outline just bites into the upper one, as on the game's title.
let captionAdvance: CGFloat = 0.9

/// The biggest lettering at which every line of every caption fits `width`, so a whole
/// set is lettered at one size.
func captionSize(_ captions: [[String]], width: CGFloat, limit: CGFloat) -> CGFloat {
    let font = CTFontCreateWithName("LilitaOne" as CFString, 100, nil)
    let widest = captions.joined().map { linePath($0.uppercased(), font: font).width }.max() ?? 100
    return min(limit, width / (widest / 100 + 0.15))
}

/// The backdrop: the app icon's yellow, so the pictures sit with the icon on the store
/// page and the game's violet screens stand off it.
let backdropTop = RGB(0xFFD663), backdropBottom = RGB(0xFFBC38)
/// A device's shadow on it: the backdrop's own colour, deeper, rather than grey.
let backdropShadow = RGB(0x9A5A00)
let backdropDot = RGB(0xF7A92A)

func backdrop(_ cg: CGContext, _ size: CGSize) {
    cg.drawLinearGradient(gradient([backdropTop, backdropBottom], [0, 1]), start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
    // The dots of the disc the chameleon stands on at home, thinning out towards the
    // caption so the lettering has a plain ground.
    let short = min(size.width, size.height)
    let step = short * 0.062
    let rowStep = step * 0.866
    cg.setFillColor(backdropDot.cg(0.5))
    var row = 0
    var y = size.height + rowStep * 0.2
    while y > size.height * 0.2 {
        // Full size across the lower half, down to nothing by the caption.
        let t = min(1, max(0, (y / size.height - 0.22) / 0.4))
        let radius = step * 0.2 * (t * t * (3 - 2 * t))
        if radius > 0.6 {
            var x = (row % 2 == 0 ? 0 : step / 2) - step
            while x < size.width + step {
                cg.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                x += step
            }
        }
        y -= rowStep
        row += 1
    }
}

/// What colour a caption's second line takes for each chameleon.
func accent(_ tint: String) -> RGB {
    switch tint {
    case "sun", "lemon", "bumblebee", "gold": return RGB(0xFFD23F)
    case "bubblegum", "strawberry": return RGB(0xFF4FA6)
    case "sky": return RGB(0x3FD0F4)
    case "tangerine", "tiger": return RGB(0xFF8A3D)
    case "cherry", "ladybird", "rainbow": return RGB(0xFF5656)
    case "grape", "midnight": return RGB(0x9B7BFF)
    default: return RGB(0x8CE04A)
    }
}

/// How the chameleon keeps the device company.
enum Perch: String { case standing, lying, curled, peeking }

struct Shot {
    let image: NSImage
    let pixels: CGSize
    let lines: [String]
    let tint: String
    let perch: Perch
    var sideways: Bool { pixels.width > pixels.height }
    // A phone screen is tall and thin (about 2.2:1); an iPad's about 4:3.
    var isPhone: Bool { max(pixels.width, pixels.height) / min(pixels.width, pixels.height) > 1.7 }
    var canvas: CGSize {
        let upright = isPhone ? CGSize(width: 1320, height: 2868) : CGSize(width: 2064, height: 2752)
        return sideways ? CGSize(width: upright.height, height: upright.width) : upright
    }
    var kind: String { "\(isPhone ? "iphone" : "ipad")-\(sideways ? "landscape" : "portrait")" }
}

func frame(spec: String, outDir: String) {
    let text = (try? String(contentsOfFile: spec, encoding: .utf8)) ?? ""
    let specDir = URL(fileURLWithPath: spec).deletingLastPathComponent()
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    var shots: [Shot] = []
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, !parts[0].hasPrefix("#") else { continue }
        let path = (parts[0] as NSString).expandingTildeInPath
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : specDir.appendingPathComponent(path)
        guard let image = NSImage(contentsOf: url), let rep = image.representations.first else {
            print("can't read \(url.path)"); continue
        }
        let words = (parts.count > 2 ? parts[2] : "").split(separator: " ").map(String.init)
        let perches: [Perch] = [.standing, .peeking, .lying, .curled]
        shots.append(Shot(image: image, pixels: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh),
                          lines: parts[1].split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) },
                          tint: words.first ?? tints[shots.count % tints.count],
                          perch: words.dropFirst().first.flatMap(Perch.init) ?? perches[shots.count % perches.count]))
    }

    // One lettering size for each kind of picture, from all of its captions.
    var sizes: [String: CGFloat] = [:]
    for shot in shots where sizes[shot.kind] == nil {
        let canvas = shot.canvas
        let captions = shots.filter { $0.kind == shot.kind }.map { $0.sideways ? [$0.lines.joined(separator: " ")] : $0.lines }
        sizes[shot.kind] = captionSize(captions, width: canvas.width * 0.84, limit: min(canvas.width, canvas.height) * (shot.isPhone ? 0.128 : 0.088))
    }

    for (index, shot) in shots.enumerated() {
        let size = shot.canvas
        let lettering = sizes[shot.kind] ?? 100
        // Sideways there's no height for two lines.
        let lines = shot.sideways ? [shot.lines.joined(separator: " ")] : shot.lines
        let tilt: CGFloat = (shot.sideways ? -1.5 : -3) * .pi / 180
        let picture = draw(size) { cg in
            backdrop(cg, size)

            // From the top: a margin, the caption, room for a chameleon to stand, then
            // the device down to a margin at the bottom. Every picture of a kind is laid
            // out from the same numbers, so the device never moves from one to the next.
            let short = min(size.width, size.height)
            let font = CTFontCreateWithName("LilitaOne" as CFString, lettering, nil)
            let outline = captionOutline(lettering)
            let block = CTFontGetCapHeight(font) + CGFloat(lines.count - 1) * lettering * captionAdvance
            // A tipped line's ends sit above and below its middle.
            let tip = abs(sin(tilt)) * size.width * 0.42
            let centre = CGPoint(x: size.width / 2, y: size.height * 0.05 + tip + outline + block / 2)
            let captionFoot = centre.y + block / 2 + outline * 2.1
            let side = short * (shot.isPhone ? 0.225 : 0.14) * (shot.sideways ? 0.62 : 1)
            // A standing chameleon is about 0.72 of its picture tall; a little air above it.
            let head = captionFoot + side * 0.72 + short * 0.02
            let foot = size.height * 0.035

            let template = shot.isPhone ? Device.phone : Device.pad
            let device = template.fitting(aspect: max(shot.pixels.width, shot.pixels.height) / min(shot.pixels.width, shot.pixels.height))
            let upright = device.size
            let shape = shot.sideways ? CGSize(width: upright.height, height: upright.width) : upright
            let scale = min((size.height - head - foot) / shape.height, size.width * 0.9 / shape.width)
            let rect = CGRect(x: (size.width - shape.width * scale) / 2, y: head, width: shape.width * scale, height: shape.height * scale)

            var coloured: [(text: String, fill: RGB)] = lines.map { ($0, RGB(0xFFFFFF)) }
            if coloured.count > 1 { coloured[coloured.count - 1].fill = accent(shot.tint) }
            drawCaption(cg, coloured, centre: centre, size: lettering, tilt: tilt)

            // The chameleon: on the device's top edge, or looking over it from behind.
            let pose: CharacterPose = shot.perch == .lying ? .lying : shot.perch == .curled ? .curled : .standing
            // Seen from the front it's narrower: a bigger picture, for a head the same size.
            let picture = shot.perch == .peeking ? side * 1.3 : side
            let mascot = chameleon(shot.tint, size: Int(picture), pose: pose, view: shot.perch == .peeking ? .front : .hero, shadow: false)
            let figure = opaqueBounds(mascot)
            let k = picture / CGFloat(mascot.representations.first?.pixelsWide ?? Int(picture))
            let standsAt = rect.minX + rect.width * 0.72
            // Looking over, its eyes clear the edge and the rest of it is behind the device.
            let sink = shot.perch == .peeking ? figure.height * k * 0.46 : rect.width * 0.004
            let place = CGRect(x: standsAt - figure.midX * k, y: rect.minY - figure.maxY * k + sink, width: picture, height: picture)
            func drawMascot() {
                mascot.draw(in: place, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }

            if shot.perch == .peeking { drawMascot() }
            drawDevice(cg, device, shot: shot.image, in: rect, sideways: shot.sideways, shadow: backdropShadow.cg(0.42))
            if shot.perch != .peeking { drawMascot() }
        }
        save(picture, String(format: "%@/%02d-%@.png", outDir, index + 1, shot.kind), opaque: true)
    }
}

/// Where a picture isn't see-through, in its own pixels (top-down).
func opaqueBounds(_ image: NSImage) -> CGRect {
    guard let rep = image.representations.first as? NSBitmapImageRep, let data = rep.bitmapData else {
        return CGRect(origin: .zero, size: image.size)
    }
    var minX = rep.pixelsWide, maxX = -1, minY = rep.pixelsHigh, maxY = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where data[y * rep.bytesPerRow + x * 4 + 3] > 40 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    return maxX < 0 ? CGRect(origin: .zero, size: image.size) : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
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
    storeshots frame <spec.txt> <outdir>   (spec lines: image.png | First line / Second line | chameleon [standing|peeking|lying|curled])
    storeshots crew <outdir>
    storeshots icons <outdir>
    storeshots card <photo.png> <headline> <out.png> [detail]
    """)
}
