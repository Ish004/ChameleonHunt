//
//  SceneAssets.swift
//  Converts core geometry into RealityKit meshes and materials.
//

import RealityKit
import UIKit

@MainActor
enum SceneAssets {

    static func mesh(_ buffers: RenderBuffers, name: String) throws -> MeshResource {
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffers.Positions(buffers.positions)
        descriptor.normals = MeshBuffers.Normals(buffers.normals)
        if !buffers.uvs.isEmpty {
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(buffers.uvs)
        }
        descriptor.primitives = .triangles(buffers.indices)
        return try MeshResource.generate(from: [descriptor])
    }

    /// Untextured mesh straight from the quad mesh (shared vertices) — for the placement ghost.
    static func ghostMesh(_ shape: CharacterShape) throws -> MeshResource {
        var buffers = RenderBuffers()
        buffers.positions = shape.mesh.positions
        buffers.normals = shape.mesh.normals
        buffers.indices.reserveCapacity(shape.mesh.quads.count * 6)
        for q in shape.mesh.quads {
            let a = UInt32(q[0]), b = UInt32(q[1]), c = UInt32(q[2]), d = UInt32(q[3])
            buffers.indices.append(contentsOf: [a, b, c, a, c, d])
        }
        return try mesh(buffers, name: "ghost-\(shape.pose.rawValue)")
    }

    // MARK: Colours that match the camera picture

    /// What to store in a chameleon's texture for it to show as the colour wanted: the
    /// measurement made on this device if there is one (and it's switched on), otherwise
    /// the curve fitted to the playtest screenshots. See DisplayCurve for the story.
    static var displayCurve: DisplayCurve { usesMeasuredCurve ? measuredCurve ?? .fallback : .fallback }
    /// What this device measured (ARSessionController.calibrateColours), kept for as long
    /// as the app runs: the renderer doesn't change.
    static var measuredCurve: DisplayCurve?
    /// Debug: off uses the fitted curve only, to compare the two on a device.
    static var usesMeasuredCurve = true

    /// A chameleon's paint, drawn as painted: no lighting (so no shading gradient gives
    /// the silhouette away) and no tone mapping. What reaches the screen is then a fixed
    /// function of the texture alone, which `displayCurve` undoes: store
    /// `displayCurve.apply(pixels)` in the texture, and the pixels are what's seen.
    static func camouflage(_ texture: TextureResource) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: .init(texture))
        return material
    }

    /// The paint in the studio, where it's seen beside the scanned room (`environment`)
    /// rather than the camera: the two are drawn the same way, RealityKit's own, so they
    /// agree with each other exactly as they always have.
    static func studioPaint(_ texture: TextureResource) -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        return material
    }

    /// Lit version for the studio, so a still-white figure's shape is readable.
    static func shaded(_ texture: TextureResource) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .white, texture: .init(texture))
        material.roughness = .init(floatLiteral: 0.9)
        material.metallic = .init(floatLiteral: 0)
        return material
    }

    /// The scanned room in the studio. Double-sided because LiDAR winding is unreliable.
    static func environment(_ texture: TextureResource) -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.faceCulling = .none
        return material
    }

    /// The placing preview: white where it can go, a faint grey where it can't.
    static func ghost(valid: Bool) -> UnlitMaterial {
        var material = UnlitMaterial(color: valid ? UIColor.white : UIColor(white: 0.55, alpha: 1))
        material.blending = .transparent(opacity: .init(floatLiteral: valid ? 0.6 : 0.3))
        return material
    }

    /// Solid and bright: found, highlighted or revealed. Pink, or in a squad game the
    /// colour of whoever scored it.
    static func reveal(_ colour: UIColor = .systemPink) -> UnlitMaterial {
        UnlitMaterial(color: colour)
    }

    /// Squad play: your own chameleons during the hunt, if you've asked to see them —
    /// white, and see-through (ChameleonActor.shownAsMine), unlike any find or any
    /// camouflage.
    static var mine: UnlitMaterial { UnlitMaterial(color: .white) }

    /// Pure magenta: never occurs in a camera image, so the render check can find it in a snapshot.
    static let probeColor = UIColor(red: 1, green: 0, blue: 1, alpha: 1)

    static func flat(_ color: UIColor) -> UnlitMaterial {
        UnlitMaterial(color: color)
    }

    /// A regular (non-live) texture from RGBA8 sRGB pixels — the most widely supported
    /// texture path in RealityKit.
    static func staticTexture(rgba: [UInt8], width: Int, height: Int) throws -> TextureResource {
        try TextureResource(image: image(rgba: rgba, width: width, height: height),
                            options: .init(semantic: .color, mipmapsMode: .none))
    }

    static func image(rgba: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw LiveTextureError.metalUnavailable }
        return image
    }

    /// Average color of the visible paint, for the flat-color fallback.
    static func averageColor(rgba: [UInt8], texels: [Int32]) -> UIColor {
        guard !texels.isEmpty else { return .white }
        var sum = SIMD3<Double>.zero
        let step = max(1, texels.count / 20_000)
        var count = 0.0
        for k in stride(from: 0, to: texels.count, by: step) {
            let i = Int(texels[k]) * 4
            sum += SIMD3(Double(rgba[i]), Double(rgba[i + 1]), Double(rgba[i + 2]))
            count += 1
        }
        let mean = sum / (count * 255)
        return UIColor(red: mean.x, green: mean.y, blue: mean.z, alpha: 1)
    }
}
