//
//  preview.swift
//  Renders the chameleon poses to PNGs so the shape can be judged by eye rather than
//  by reading coordinates. Build with build.sh, from the project root.
//

import AppKit
import Foundation
import simd

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

struct Camera {
    var eye: Vec3
    var target: Vec3
    var up: Vec3 = [0, 1, 0]
    var halfHeight: Float          // orthographic
}

func render(_ mesh: QuadMesh, camera: Camera, size: Int, label: String) -> NSImage {
    let forward = simd_normalize(camera.target - camera.eye)
    let right = simd_normalize(simd_cross(forward, camera.up))
    let up = simd_cross(right, forward)

    // Triangles, in view space.
    var tris: [(Vec3, Vec3, Vec3)] = []
    for quad in mesh.quads {
        let p = (0..<4).map { mesh.positions[Int(quad[$0])] }
        tris.append((p[0], p[1], p[2]))
        tris.append((p[0], p[2], p[3]))
    }

    let halfWidth = camera.halfHeight
    var depth = [Float](repeating: .greatestFiniteMagnitude, count: size * size)
    var shade = [Float](repeating: -1, count: size * size)
    let light = simd_normalize(Vec3(-0.4, 0.75, 0.6))

    func project(_ p: Vec3) -> Vec3 {
        let o = p - camera.eye
        let x = simd_dot(o, right) / halfWidth
        let y = simd_dot(o, up) / camera.halfHeight
        return Vec3((x * 0.5 + 0.5) * Float(size), (0.5 - y * 0.5) * Float(size), simd_dot(o, forward))
    }

    for (a, b, c) in tris {
        let pa = project(a), pb = project(b), pc = project(c)
        let normal = simd_normalize(simd_cross(b - a, c - a))
        let lambert = max(0.12, simd_dot(normal, light))
        let minX = max(Int(floor(min(pa.x, pb.x, pc.x))), 0), maxX = min(Int(ceil(max(pa.x, pb.x, pc.x))), size - 1)
        let minY = max(Int(floor(min(pa.y, pb.y, pc.y))), 0), maxY = min(Int(ceil(max(pa.y, pb.y, pc.y))), size - 1)
        guard minX <= maxX, minY <= maxY else { continue }
        let area = (pb.x - pa.x) * (pc.y - pa.y) - (pc.x - pa.x) * (pb.y - pa.y)
        guard abs(area) > 1e-8 else { continue }
        for y in minY...maxY {
            for x in minX...maxX {
                let px = Float(x) + 0.5, py = Float(y) + 0.5
                let w0 = ((pb.x - pa.x) * (py - pa.y) - (px - pa.x) * (pb.y - pa.y)) / area
                let w1 = ((px - pa.x) * (pc.y - pa.y) - (pc.x - pa.x) * (py - pa.y)) / area
                let w2 = 1 - w0 - w1
                guard w0 >= 0, w1 >= 0, w2 >= 0 else { continue }
                let z = pa.z * w2 + pb.z * w1 + pc.z * w0
                let i = y * size + x
                if z < depth[i] { depth[i] = z; shade[i] = lambert }
            }
        }
    }

    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    for y in 0..<size {
        for x in 0..<size {
            let s = shade[y * size + x]
            guard s >= 0 else { continue }
            let v = CGFloat(min(1, 0.25 + s * 0.8))
            NSColor(calibratedRed: v * 0.86, green: v, blue: v * 0.80, alpha: 1).setFill()
            NSRect(x: x, y: size - 1 - y, width: 1, height: 1).fill()
        }
    }
    (label as NSString).draw(at: NSPoint(x: 6, y: 4),
                             withAttributes: [.foregroundColor: NSColor.systemYellow,
                                              .font: NSFont.boldSystemFont(ofSize: 15)])
    image.unlockFocus()
    return image
}

func write(_ images: [NSImage], columns: Int, to path: String) {
    guard let first = images.first else { return }
    let cell = first.size
    let rows = (images.count + columns - 1) / columns
    let sheet = NSImage(size: NSSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows)))
    sheet.lockFocus()
    for (i, image) in images.enumerated() {
        let c = CGFloat(i % columns), r = CGFloat(i / columns)
        image.draw(in: NSRect(x: c * cell.width, y: sheet.size.height - (r + 1) * cell.height,
                              width: cell.width, height: cell.height))
    }
    sheet.unlockFocus()
    let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}


func mascotImage(_ image: MascotRenderer.Image, label: String, background: NSColor) -> NSImage {
    let result = NSImage(size: NSSize(width: image.width, height: image.height))
    result.lockFocus()
    background.setFill()
    NSRect(x: 0, y: 0, width: image.width, height: image.height).fill()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: image.width * 4,
                               bitsPerPixel: 32)!
    image.pixels.withUnsafeBytes { raw in
        rep.bitmapData!.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: image.pixels.count)
    }
    let drawn = NSImage(size: NSSize(width: image.width, height: image.height))
    drawn.addRepresentation(rep)
    drawn.draw(in: NSRect(x: 0, y: 0, width: image.width, height: image.height),
               from: .zero, operation: .sourceOver, fraction: 1)
    (label as NSString).draw(at: NSPoint(x: 8, y: 6), withAttributes: [.foregroundColor: NSColor.darkGray,
                                                                    .font: NSFont.boldSystemFont(ofSize: 14)])
    result.unlockFocus()
    return result
}

// The app icon: the chameleon on a warm sun-yellow tile. Opaque, as the App Store
// requires, so it's drawn without an alpha channel.
if let flag = CommandLine.arguments.firstIndex(of: "--icon"), flag + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[flag + 1]
    let size = 1024
    let figure = MascotRenderer.render(.standing, view: .hero, size: 900)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: size * 3, bitsPerPixel: 24)!
    let out = rep.bitmapData!
    let top = SIMD3<Float>(1.00, 0.84, 0.39), bottom = SIMD3<Float>(1.00, 0.74, 0.22)
    let offsetX = (size - figure.width) / 2, offsetY = (size - figure.height) / 2 + 30
    for y in 0..<size {
        let t = Float(y) / Float(size - 1)
        let ground = top + (bottom - top) * t
        for x in 0..<size {
            var c = ground
            let fx = x - offsetX, fy = y - offsetY
            if fx >= 0, fy >= 0, fx < figure.width, fy < figure.height {
                let i = (fy * figure.width + fx) * 4
                let a = Float(figure.pixels[i + 3]) / 255
                let premultiplied = SIMD3<Float>(Float(figure.pixels[i]), Float(figure.pixels[i + 1]), Float(figure.pixels[i + 2])) / 255
                c = premultiplied + c * (1 - a)
            }
            let o = y * size * 3 + x * 3
            out[o] = UInt8(min(255, c.x * 255)); out[o + 1] = UInt8(min(255, c.y * 255)); out[o + 2] = UInt8(min(255, c.z * 255))
        }
    }
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
    exit(0)
}

// Every skin, as the shop shows it: `preview <outdir> --skins`.
if CommandLine.arguments.contains("--skins") {
    let ground = NSColor(calibratedRed: 0.17, green: 0.08, blue: 0.55, alpha: 1)
    let images = ChameleonSkin.allCases.map { skin in
        mascotImage(MascotRenderer.render(.standing, view: .hero, size: 300, palette: skin.palette),
                    label: "\(skin.title) · \(skin.price)", background: ground)
    }
    write(images, columns: 4, to: "\(outDir)/skins.png")
    exit(0)
}

if CommandLine.arguments.contains("--mascot") {
    var images: [NSImage] = []
    let ground = NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.92, alpha: 1)
    for pose in CharacterPose.allCases {
        for (name, view) in [("hero", MascotRenderer.View.hero), ("side", .side), ("front", .front)] {
            let start = Date()
            let image = MascotRenderer.render(pose, view: view, size: 360)
            if name == "hero" { print(String(format: "%@ rendered in %.0f ms", pose.rawValue, Date().timeIntervalSince(start) * 1000)) }
            images.append(mascotImage(image, label: "\(pose.rawValue) \(name)", background: ground))
        }
    }
    write(images, columns: 3, to: "\(outDir)/mascot.png")
    exit(0)
}

var sheet: [NSImage] = []

for pose in CharacterPose.allCases {
    let shape = CharacterShape.build(pose)
    let lo = shape.mesh.positions.reduce(Vec3(repeating: .greatestFiniteMagnitude), simd_min)
    let hi = shape.mesh.positions.reduce(Vec3(repeating: -.greatestFiniteMagnitude), simd_max)
    let centre = (lo + hi) * 0.5
    let extent = simd_length(hi - lo) * 0.52
    print(String(format: "%@: %d quads, %.0f x %.0f x %.0f cm", pose.rawValue, shape.mesh.quads.count,
                 (hi.x - lo.x) * 100, (hi.y - lo.y) * 100, (hi.z - lo.z) * 100))
    let views: [(String, Vec3)] = [("side", [1.4, 0.25, 0.1]), ("3/4", [1.0, 0.55, 1.0]),
                                   ("front", [0.08, 0.30, 1.4]), ("top", [0.15, 1.4, 0.25])]
    for (name, direction) in views {
        let camera = Camera(eye: centre + simd_normalize(direction) * 2, target: centre,
                            up: abs(simd_normalize(direction).y) > 0.9 ? [0, 0, -1] : [0, 1, 0],
                            halfHeight: extent)
        sheet.append(render(shape.mesh, camera: camera, size: 300, label: "\(pose.rawValue) \(name)"))
    }
}
write(sheet, columns: 4, to: "\(outDir)/poses.png")
