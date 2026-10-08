//
//  LightingEstimate.swift
//  Turns "the camera sees this / the scan recorded that" samples into a brightness
//  and white-balance correction for the paint.
//
//  Deliberately cautious: a median ignores samples that landed on the wrong surface,
//  the channels can only drift so far apart (a correction, not a recolor), the whole
//  thing is clamped to a sane range, and it eases toward the new value so the
//  character never flashes.
//

import simd

enum LightingEstimate {

    /// Overall brightness correction allowed.
    static let range: ClosedRange<Float> = 0.55...2.2
    /// How far individual channels may differ from that overall correction.
    static let channelSpread: ClosedRange<Float> = 0.82...1.22
    static let minimumSamples = 6

    /// - Parameters:
    ///   - ratios: live color ÷ scanned color, in linear light, per sample.
    ///   - previous: the gain in use, eased toward the new estimate.
    /// - Returns: the new gain, or nil if there weren't enough samples to trust.
    static func gain(from ratios: [Color3], previous: Color3, smoothing: Float = 0.3) -> Color3? {
        guard ratios.count >= minimumSamples else { return nil }

        var target = Color3(median(ratios.map(\.x)), median(ratios.map(\.y)), median(ratios.map(\.z)))
        let overall = min(max((target.x + target.y + target.z) / 3, range.lowerBound), range.upperBound)
        target = simd_clamp(target,
                            Color3(repeating: overall * channelSpread.lowerBound),
                            Color3(repeating: overall * channelSpread.upperBound))
        target = simd_clamp(target, Color3(repeating: range.lowerBound), Color3(repeating: range.upperBound))
        return previous + (target - previous) * smoothing
    }

    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 1 }
        let sorted = values.sorted()
        return sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    /// Scales an sRGB-encoded byte by a linear-light gain (the paint is stored as sRGB).
    static func lookupTable(gain: Color3) -> [UInt8] {
        var table = [UInt8](repeating: 0, count: 256 * 3)
        for channel in 0..<3 {
            let g = gain[channel]
            for value in 0..<256 {
                let scaled = linearToSRGB(srgbToLinear(Float(value) / 255) * g)
                table[channel * 256 + value] = UInt8(clamp01(scaled) * 255 + 0.5)
            }
        }
        return table
    }
}
