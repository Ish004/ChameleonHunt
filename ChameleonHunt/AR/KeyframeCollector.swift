//
//  KeyframeCollector.swift
//  Decides which camera frames to keep while the hider scans, and converts them
//  into `Keyframe`s for the baker.
//
//  A frame is kept when tracking is solid, the phone isn't moving fast enough to
//  blur, the hiding spot is comfortably inside the image and still where it was, and
//  the viewpoint is meaningfully different from every keyframe already captured.
//  Coverage is tracked in 16 buckets around the spot (8 directions x low/high angle) so
//  the UI can tell the player where they still need to walk.
//
//  Every frame turned down for a reason the player can fix is counted, so the scan can
//  say what actually went wrong ("Too fast") instead of a general "try again".
//

import ARKit
import Foundation

/// Copies of the camera image planes, safe to convert off the main thread.
struct CapturedPlanes: Sendable {
    let width: Int
    let height: Int
    let lumaStride: Int
    let luma: [UInt8]
    let chromaWidth: Int
    let chromaHeight: Int
    let chromaStride: Int
    let chroma: [UInt8]
    let fullRange: Bool
}

@MainActor
final class KeyframeCollector {

    /// Why a frame wasn't kept, in terms the player can act on.
    enum Problem: String, CaseIterable, Sendable {
        case tooFast, tooDark, lostTracking, offCentre, tooClose, tooFar, spotMoved, blocked
    }

    nonisolated static let maxKeyframes = 36
    nonisolated static let outputWidth = 1440
    nonisolated static let bucketCount = 16

    private(set) var keyframes: [Keyframe] = []
    private(set) var coverage = [Bool](repeating: false, count: bucketCount)
    /// How many frames each problem cost, this scan.
    private(set) var problems: [Problem: Int] = [:]
    /// The latest problem, and when — for a live nudge.
    private(set) var latestProblem: (problem: Problem, at: TimeInterval)?
    /// Called after each keyframe lands, with where the camera was.
    var onChange: ((Vec3) -> Void)?

    /// What cost the most frames, if anything did.
    var mainProblem: Problem? {
        problems.max { $0.value < $1.value }.flatMap { $0.value >= 3 ? $0.key : nil }
    }

    private var anchorToWorld = matrix_identity_float4x4
    private var pendingConversions = 0
    private var lastCaptureTime: TimeInterval = 0
    private var lastTransform: simd_float4x4?
    private var lastTimestamp: TimeInterval = 0
    private var generation = 0

    var coveredBuckets: Int { coverage.filter { $0 }.count }

    func reset(anchorToWorld: simd_float4x4) {
        self.anchorToWorld = anchorToWorld
        keyframes.removeAll()
        coverage = [Bool](repeating: false, count: Self.bucketCount)
        problems = [:]
        latestProblem = nil
        lastTransform = nil
        lastCaptureTime = 0
        generation += 1
    }

    func consider(_ frame: ARFrame) {
        let transform = frame.camera.transform
        defer {
            lastTransform = transform
            lastTimestamp = frame.timestamp
        }

        guard keyframes.count + pendingConversions < Self.maxKeyframes,
              pendingConversions < 2,
              frame.timestamp - lastCaptureTime > 0.25 else { return }

        switch frame.camera.trackingState {
        case .normal: break
        case .limited(.excessiveMotion): return note(.tooFast, at: frame.timestamp)
        case .limited(.insufficientFeatures): return note(.tooDark, at: frame.timestamp)
        default: return note(.lostTracking, at: frame.timestamp)
        }

        // Reject motion blur.
        if let last = lastTransform, frame.timestamp > lastTimestamp {
            let dt = Float(frame.timestamp - lastTimestamp)
            let speed = simd_length(transform.translation - last.translation) / dt
            let turn = acos(min(1, max(-1, simd_dot(transform.zAxis, last.zAxis)))) / dt
            if speed > 0.35 || turn > 0.7 { return note(.tooFast, at: frame.timestamp) }
        }

        // The spot must be in view, not too close or far.
        let spot = anchorToWorld.translation
        let cameraSpace = transform.inverse.transformPoint(spot)
        let depth = -cameraSpace.z
        if depth <= 0.2 { return note(.tooClose, at: frame.timestamp) }
        if depth >= 3.0 { return note(.tooFar, at: frame.timestamp) }
        let resolution = frame.camera.imageResolution
        let k = frame.camera.intrinsics
        let u = k[0][0] * cameraSpace.x / depth + k[2][0]
        let v = k[1][1] * -cameraSpace.y / depth + k[2][1]
        let marginX = Float(resolution.width) * 0.12
        let marginY = Float(resolution.height) * 0.12
        guard u > marginX, u < Float(resolution.width) - marginX,
              v > marginY, v < Float(resolution.height) - marginY else { return note(.offCentre, at: frame.timestamp) }

        // The surface must still be where it was: a person or a pet moves, and a hand in
        // front of the lens hides it.
        if let measured = Self.depth(in: frame, u: u / Float(resolution.width), v: v / Float(resolution.height)) {
            if measured > depth + 0.10 { return note(.spotMoved, at: frame.timestamp) }
            if measured < depth - 0.15 { return note(.blocked, at: frame.timestamp) }
        }

        // Must add a genuinely new viewpoint.
        for existing in keyframes {
            let move = simd_length(existing.cameraToWorld.translation - transform.translation) / 0.12
            let angle = acos(min(1, max(-1, simd_dot(existing.cameraToWorld.zAxis, transform.zAxis)))) / (15 * .pi / 180)
            if move + angle < 1 { return }
        }

        capture(frame)
    }

    private func note(_ problem: Problem, at timestamp: TimeInterval) {
        problems[problem, default: 0] += 1
        latestProblem = (problem, timestamp)
    }

    /// LiDAR depth at a point in the image (0…1 across and down), if it's confident.
    private static func depth(in frame: ARFrame, u: Float, v: Float) -> Float? {
        guard let sceneDepth = frame.sceneDepth else { return nil }
        let map = sceneDepth.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let x = min(max(Int(u * Float(width)), 0), width - 1)
        let y = min(max(Int(v * Float(height)), 0), height - 1)
        let row = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<Float32>.size
        if let confidence = sceneDepth.confidenceMap {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
            if let levels = CVPixelBufferGetBaseAddress(confidence)?.assumingMemoryBound(to: UInt8.self),
               CVPixelBufferGetWidth(confidence) == width,
               levels[y * CVPixelBufferGetBytesPerRow(confidence) + x] < UInt8(ARConfidenceLevel.high.rawValue) {
                return nil
            }
        }
        let value = base.assumingMemoryBound(to: Float32.self)[y * row + x]
        return value > 0 ? value : nil
    }

    private func capture(_ frame: ARFrame) {
        guard let planes = Self.copyPlanes(frame.capturedImage) else { return }
        let (depthWidth, depthHeight, depth) = Self.copyDepth(frame)

        let camera = frame.camera
        let scale = Float(min(Self.outputWidth, planes.width)) / Float(planes.width)
        let intrinsics = SIMD4<Float>(camera.intrinsics[0][0] * scale, camera.intrinsics[1][1] * scale,
                                      camera.intrinsics[2][0] * scale, camera.intrinsics[2][1] * scale)
        let cameraToWorld = camera.transform
        let capturedGeneration = generation

        lastCaptureTime = frame.timestamp
        pendingConversions += 1

        Task.detached(priority: .userInitiated) {
            let (width, height, rgba) = Self.convert(planes, outputWidth: Self.outputWidth)
            let keyframe = Keyframe(width: width, height: height, rgba: rgba, intrinsics: intrinsics,
                                    cameraToWorld: cameraToWorld, depthWidth: depthWidth,
                                    depthHeight: depthHeight, depth: depth)
            await MainActor.run {
                self.pendingConversions -= 1
                guard capturedGeneration == self.generation else { return }
                self.keyframes.append(keyframe)
                self.markCoverage(cameraPosition: cameraToWorld.translation)
                self.onChange?(cameraToWorld.translation)
            }
        }
    }

    private func markCoverage(cameraPosition: Vec3) {
        let local = anchorToWorld.inverse.transformPoint(cameraPosition)
        let length = simd_length(local)
        guard length > 1e-3 else { return }
        let direction = local / length
        let elevation = asin(min(1, max(-1, direction.y)))
        guard elevation > 5 * .pi / 180 else { return }
        let azimuth = atan2(direction.x, direction.z) + .pi
        let sector = min(7, Int(azimuth / (2 * .pi) * 8))
        let ring = elevation < 40 * .pi / 180 ? 0 : 1
        coverage[ring * 8 + sector] = true
    }

    // MARK: - Frame copies (main thread, fast memcpy)

    static func copyPlanes(_ buffer: CVPixelBuffer) -> CapturedPlanes? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard fullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) >= 2 else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }

        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        let luma = [UInt8](UnsafeBufferPointer(start: lumaBase.assumingMemoryBound(to: UInt8.self),
                                               count: lumaStride * height))
        let chroma = [UInt8](UnsafeBufferPointer(start: chromaBase.assumingMemoryBound(to: UInt8.self),
                                                 count: chromaStride * chromaHeight))
        return CapturedPlanes(width: width, height: height, lumaStride: lumaStride, luma: luma,
                              chromaWidth: chromaWidth, chromaHeight: chromaHeight,
                              chromaStride: chromaStride, chroma: chroma, fullRange: fullRange)
    }

    /// LiDAR depth aligned with the camera image; low-confidence samples become 0.
    static func copyDepth(_ frame: ARFrame) -> (Int, Int, [Float]) {
        guard let sceneDepth = frame.sceneDepth else { return (0, 0, []) }
        let map = sceneDepth.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(map) else { return (0, 0, []) }

        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let stride = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<Float32>.size
        let source = base.assumingMemoryBound(to: Float32.self)
        var depth = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                depth[y * width + x] = source[y * stride + x]
            }
        }

        if let confidence = sceneDepth.confidenceMap {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
            if let confidenceBase = CVPixelBufferGetBaseAddress(confidence),
               CVPixelBufferGetWidth(confidence) == width, CVPixelBufferGetHeight(confidence) == height {
                let confidenceStride = CVPixelBufferGetBytesPerRow(confidence)
                let levels = confidenceBase.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width where levels[y * confidenceStride + x] < UInt8(ARConfidenceLevel.medium.rawValue) {
                        depth[y * width + x] = 0
                    }
                }
            }
        }
        return (width, height, depth)
    }

    // MARK: - YCbCr -> RGBA (background)

    nonisolated static func convert(_ planes: CapturedPlanes, outputWidth: Int) -> (Int, Int, [UInt8]) {
        let width = min(outputWidth, planes.width)
        let height = planes.height * width / planes.width
        let scale = Float(planes.width) / Float(width)
        var rgba = [UInt8](repeating: 255, count: width * height * 4)

        rgba.withUnsafeMutableBufferPointer { output in
            let out = UnsafeSendablePointer(base: output.baseAddress!)
            Parallel.forEachChunk(count: height, minimumChunk: 16) { rows in
                planes.luma.withUnsafeBufferPointer { luma in
                    planes.chroma.withUnsafeBufferPointer { chroma in
                        for y in rows {
                            let sy = (Float(y) + 0.5) * scale - 0.5
                            let y0 = min(max(Int(sy), 0), planes.height - 1)
                            let y1 = min(y0 + 1, planes.height - 1)
                            let fy = max(0, sy - Float(y0))
                            let chromaRow = min(Int((Float(y) + 0.5) * scale) / 2, planes.chromaHeight - 1)
                            for x in 0..<width {
                                let sx = (Float(x) + 0.5) * scale - 0.5
                                let x0 = min(max(Int(sx), 0), planes.width - 1)
                                let x1 = min(x0 + 1, planes.width - 1)
                                let fx = max(0, sx - Float(x0))
                                let top = Float(luma[y0 * planes.lumaStride + x0]) * (1 - fx) + Float(luma[y0 * planes.lumaStride + x1]) * fx
                                let bottom = Float(luma[y1 * planes.lumaStride + x0]) * (1 - fx) + Float(luma[y1 * planes.lumaStride + x1]) * fx
                                var lumaValue = top * (1 - fy) + bottom * fy

                                let chromaColumn = min(Int((Float(x) + 0.5) * scale) / 2, planes.chromaWidth - 1)
                                let ci = chromaRow * planes.chromaStride + chromaColumn * 2
                                var cb = Float(chroma[ci]) - 128
                                var cr = Float(chroma[ci + 1]) - 128
                                if !planes.fullRange {
                                    lumaValue = (lumaValue - 16) * (255 / 219)
                                    cb *= 255 / 224
                                    cr *= 255 / 224
                                }
                                // BT.601
                                let r = lumaValue + 1.402 * cr
                                let g = lumaValue - 0.344136 * cb - 0.714136 * cr
                                let b = lumaValue + 1.772 * cb
                                let i = (y * width + x) * 4
                                out.base[i] = UInt8(min(max(r, 0), 255))
                                out.base[i + 1] = UInt8(min(max(g, 0), 255))
                                out.base[i + 2] = UInt8(min(max(b, 0), 255))
                            }
                        }
                    }
                }
            }
        }
        return (width, height, rgba)
    }
}

/// A camera frame, copied out quickly on the main thread and converted to RGB off it, for
/// the chameleons' living camouflage. Much smaller than a scan keyframe: the chameleon only
/// covers a small part of the view, and speed matters more than detail here.
struct LiveFrameSnapshot: Sendable {
    let planes: CapturedPlanes
    let intrinsics: SIMD4<Float>
    let cameraToWorld: simd_float4x4
    let depthWidth: Int
    let depthHeight: Int
    let depth: [Float]
    let outputWidth: Int

    @MainActor
    init?(_ frame: ARFrame, outputWidth: Int = 640) {
        guard let planes = KeyframeCollector.copyPlanes(frame.capturedImage) else { return nil }
        let (depthWidth, depthHeight, depth) = KeyframeCollector.copyDepth(frame)
        let camera = frame.camera
        let scale = Float(min(outputWidth, planes.width)) / Float(planes.width)
        self.planes = planes
        intrinsics = SIMD4<Float>(camera.intrinsics[0][0] * scale, camera.intrinsics[1][1] * scale,
                                  camera.intrinsics[2][0] * scale, camera.intrinsics[2][1] * scale)
        cameraToWorld = camera.transform
        self.depthWidth = depthWidth
        self.depthHeight = depthHeight
        self.depth = depth
        self.outputWidth = outputWidth
    }

    func keyframe() -> Keyframe {
        let (width, height, rgba) = KeyframeCollector.convert(planes, outputWidth: outputWidth)
        return Keyframe(width: width, height: height, rgba: rgba, intrinsics: intrinsics,
                        cameraToWorld: cameraToWorld, depthWidth: depthWidth, depthHeight: depthHeight, depth: depth)
    }
}

