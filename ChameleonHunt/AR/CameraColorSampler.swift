//
//  CameraColorSampler.swift
//  Reads the color of the live camera feed at a point on screen.
//
//  `ARFrame.capturedImage` is bi-planar YCbCr 4:2:0 in the sensor's own orientation:
//  plane 0 is full-resolution luma, plane 1 is half-resolution interleaved Cb/Cr.
//  `ARFrame.displayTransform(for:viewportSize:)` maps normalized image space to the
//  view, so inverting it turns a point on screen into the right sensor pixel — the
//  part that's easy to get wrong by assuming the image is upright and uncropped.
//
//  Used by the lighting match to compare what the camera sees now against what the
//  scan recorded for the same surfaces.
//

import ARKit
import UIKit

enum CameraColorSampler {

    /// Average color of a small patch of the camera image at a point in view coordinates.
    static func color(from frame: ARFrame, at viewPoint: CGPoint, viewportSize: CGSize,
                      orientation: UIInterfaceOrientation, patchRadius: Int = 3) -> Color3? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }

        let buffer = frame.capturedImage
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let isFullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard isFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) >= 2 else { return nil }

        let normalized = CGPoint(x: viewPoint.x / viewportSize.width, y: viewPoint.y / viewportSize.height)
            .applying(frame.displayTransform(for: orientation, viewportSize: viewportSize).inverted())

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }

        let lumaWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        let centerX = Int((normalized.x * CGFloat(lumaWidth)).rounded())
        let centerY = Int((normalized.y * CGFloat(lumaHeight)).rounded())
        guard centerX >= 0, centerY >= 0, centerX < lumaWidth, centerY < lumaHeight else { return nil }

        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)

        var sumY = 0.0, sumCb = 0.0, sumCr = 0.0, samples = 0.0
        for dy in -patchRadius...patchRadius {
            let py = min(max(centerY + dy, 0), lumaHeight - 1)
            for dx in -patchRadius...patchRadius {
                let px = min(max(centerX + dx, 0), lumaWidth - 1)
                sumY += Double(luma[py * lumaStride + px])
                let cx = min(px / 2, chromaWidth - 1)
                let cy = min(py / 2, chromaHeight - 1)
                let index = cy * chromaStride + cx * 2
                sumCb += Double(chroma[index])
                sumCr += Double(chroma[index + 1])
                samples += 1
            }
        }
        guard samples > 0 else { return nil }

        var y = sumY / samples
        var cb = sumCb / samples - 128
        var cr = sumCr / samples - 128
        if !isFullRange {
            y = (y - 16) * (255 / 219)
            cb *= 255 / 224
            cr *= 255 / 224
        }
        // BT.601, already gamma-encoded sRGB.
        let r = y + 1.402 * cr
        let g = y - 0.344136 * cb - 0.714136 * cr
        let b = y + 1.772 * cb
        return Color3(clamp01(Float(r / 255)), clamp01(Float(g / 255)), clamp01(Float(b / 255)))
    }
}
