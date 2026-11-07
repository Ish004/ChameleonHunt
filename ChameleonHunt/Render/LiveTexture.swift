//
//  LiveTexture.swift
//  A RealityKit texture we can repaint many times a second.
//
//  `TextureResource.replace(withImage:)` rebuilds the whole texture from a CGImage,
//  which is far too slow to call on every Pencil sample. Instead the pixels go
//  into a CPU-visible Metal staging texture (only the dirty rectangle is copied),
//  and a GPU blit pushes that into a `LowLevelTexture` that RealityKit renders
//  directly. The same `resource` is shared by the studio and the AR view, so the
//  hunt shows exactly what was painted.
//

import Metal
import RealityKit

enum LiveTextureError: Error {
    case metalUnavailable
}

@MainActor
final class LiveTexture {
    let resource: TextureResource
    let width: Int
    let height: Int

    private let lowLevel: LowLevelTexture
    private let staging: MTLTexture
    private let queue: MTLCommandQueue

    /// - Parameter pixelFormat: `.rgba8Unorm_srgb` for colors, `.rgba8Unorm` for data (e.g. depth).
    init(width: Int, height: Int, pixelFormat: MTLPixelFormat = .rgba8Unorm_srgb) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw LiveTextureError.metalUnavailable }
        self.width = width
        self.height = height
        self.queue = queue

        let descriptor = LowLevelTexture.Descriptor(pixelFormat: pixelFormat,
                                                    width: width, height: height, depth: 1,
                                                    mipmapLevelCount: 1,
                                                    textureUsage: [.shaderRead])
        lowLevel = try LowLevelTexture(descriptor: descriptor)
        resource = try TextureResource(from: lowLevel)

        let stagingDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                         width: width, height: height,
                                                                         mipmapped: false)
        stagingDescriptor.storageMode = .shared
        stagingDescriptor.usage = [.shaderRead]
        guard let staging = device.makeTexture(descriptor: stagingDescriptor) else {
            throw LiveTextureError.metalUnavailable
        }
        self.staging = staging
    }

    /// Copies `dirty` (or everything) from `pixels` and pushes it to the GPU.
    func upload(_ pixels: [UInt8], dirty: DirtyRect?) {
        precondition(pixels.count == width * height * 4, "Pixel buffer size mismatch")
        let rect = dirty ?? DirtyRect(minX: 0, minY: 0, maxX: width - 1, maxY: height - 1)
        let minX = max(0, rect.minX), minY = max(0, rect.minY)
        let maxX = min(width - 1, rect.maxX), maxY = min(height - 1, rect.maxY)
        guard minX <= maxX, minY <= maxY else { return }

        pixels.withUnsafeBytes { raw in
            staging.replace(region: MTLRegionMake2D(minX, minY, maxX - minX + 1, maxY - minY + 1),
                            mipmapLevel: 0,
                            withBytes: raw.baseAddress!.advanced(by: (minY * width + minX) * 4),
                            bytesPerRow: width * 4)
        }

        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        let destination = lowLevel.replace(using: commandBuffer)
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            // The replacement texture isn't guaranteed to hold the previous contents,
            // so copy the whole staging texture (a trivial GPU copy).
            blit.copy(from: staging, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: destination, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        commandBuffer.commit()
    }
}
