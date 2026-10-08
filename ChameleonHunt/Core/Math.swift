//
//  Math.swift
//  Small shared vocabulary for the geometry / painting core. Everything in Core/
//  is plain Swift + simd (no ARKit, no RealityKit) so it can be unit-tested on a Mac.
//

import Foundation
import simd

typealias Vec2 = SIMD2<Float>
typealias Vec3 = SIMD3<Float>
/// An sRGB color with components in 0...1.
typealias Color3 = SIMD3<Float>

extension simd_float4x4 {
    init(translation t: Vec3) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
    }

    init(uniformScale s: Float) {
        self = matrix_identity_float4x4
        columns.0.x = s
        columns.1.y = s
        columns.2.z = s
    }

    /// Builds a rigid transform from an orthonormal basis and an origin.
    init(xAxis: Vec3, yAxis: Vec3, zAxis: Vec3, origin: Vec3) {
        self.init(SIMD4<Float>(xAxis, 0),
                  SIMD4<Float>(yAxis, 0),
                  SIMD4<Float>(zAxis, 0),
                  SIMD4<Float>(origin, 1))
    }

    @inline(__always) func transformPoint(_ p: Vec3) -> Vec3 {
        let r = self * SIMD4<Float>(p.x, p.y, p.z, 1)
        return Vec3(r.x, r.y, r.z)
    }

    @inline(__always) func transformDirection(_ d: Vec3) -> Vec3 {
        let r = self * SIMD4<Float>(d.x, d.y, d.z, 0)
        return Vec3(r.x, r.y, r.z)
    }

    var translation: Vec3 { Vec3(columns.3.x, columns.3.y, columns.3.z) }
    var xAxis: Vec3 { Vec3(columns.0.x, columns.0.y, columns.0.z) }
    var yAxis: Vec3 { Vec3(columns.1.x, columns.1.y, columns.1.z) }
    var zAxis: Vec3 { Vec3(columns.2.x, columns.2.y, columns.2.z) }
}

@inline(__always) func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }

@inline(__always) func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = clamp01((x - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
}

/// Any vector perpendicular to `v` (which must be non-zero).
@inline(__always) func anyPerpendicular(to v: Vec3) -> Vec3 {
    let helper: Vec3 = abs(v.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]
    return simd_normalize(simd_cross(v, helper))
}

/// sRGB encoding, used whenever colors are scaled: brightness has to be multiplied
/// in linear light, not on the gamma-encoded bytes.
@inline(__always) func srgbToLinear(_ v: Float) -> Float {
    v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}

@inline(__always) func linearToSRGB(_ v: Float) -> Float {
    let c = max(v, 0)
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
}

// MARK: - Pixels

/// Inclusive pixel-space rectangle used to upload only what a brush stroke touched.
struct DirtyRect: Sendable, Equatable {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int

    init(x: Int, y: Int) {
        minX = x; maxX = x
        minY = y; maxY = y
    }

    init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        self.minX = minX; self.minY = minY
        self.maxX = maxX; self.maxY = maxY
    }

    mutating func include(x: Int, y: Int) {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }

    mutating func formUnion(_ other: DirtyRect) {
        minX = min(minX, other.minX); maxX = max(maxX, other.maxX)
        minY = min(minY, other.minY); maxY = max(maxY, other.maxY)
    }

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
}

extension Optional where Wrapped == DirtyRect {
    mutating func include(x: Int, y: Int) {
        if self == nil { self = DirtyRect(x: x, y: y) } else { self!.include(x: x, y: y) }
    }

    mutating func formUnion(_ other: DirtyRect?) {
        guard let other else { return }
        if self == nil { self = other } else { self!.formUnion(other) }
    }
}

@inline(__always) func packRGBA(_ c: Color3) -> (UInt8, UInt8, UInt8) {
    (UInt8(clamp01(c.x) * 255 + 0.5), UInt8(clamp01(c.y) * 255 + 0.5), UInt8(clamp01(c.z) * 255 + 0.5))
}

// MARK: - Parallelism

/// Carries a value that isn't marked Sendable (e.g. an ARKit or UIKit object) across
/// one well-understood hop, such as a completion handler into a continuation.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

/// Lets `concurrentPerform` workers write *disjoint* regions of one buffer.
/// Callers are responsible for never touching the same element from two workers.
struct UnsafeSendablePointer<T>: @unchecked Sendable {
    let base: UnsafeMutablePointer<T>
}

enum Parallel {
    /// Splits `0..<count` into chunks and runs them across all cores.
    static func forEachChunk(count: Int, minimumChunk: Int = 64, _ body: @Sendable (Range<Int>) -> Void) {
        guard count > 0 else { return }
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunkCount = max(1, min(cores * 4, (count + minimumChunk - 1) / minimumChunk))
        let chunkSize = (count + chunkCount - 1) / chunkCount
        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
            let lower = chunk * chunkSize
            let upper = min(count, lower + chunkSize)
            if lower < upper { body(lower..<upper) }
        }
    }
}
