//
//  DisplayCurve.swift
//  What to store in a chameleon's texture so that it reaches the screen as the colour
//  the camera saw.
//
//  A chameleon's texture is made of colours sampled from the camera picture, and it only
//  hides if those colours come out on screen exactly as the camera picture behind it
//  does. They don't, by themselves. RealityKit draws a texture one of two ways:
//   - tone-mapped (its default, how it was until v7.1): darker than the camera picture.
//     Measured from playtest screenshots, 7% darker on a carpet and 10–13% on a white
//     desk, where the chameleons were grey blobs; and no texture value at all comes out
//     as bright as a white desk.
//   - not tone-mapped (v7.2): brighter than the camera picture, by about 10% on the same
//     carpet. Pale ghosts instead of dark ones.
//  Neither is the identity, and nothing documents what they are. So the game measures:
//  it draws a strip of known greys the way it draws chameleons, reads back what they look
//  like on screen (ARSessionController.calibrateColours), and this type turns those
//  readings into a table: for the colour wanted on screen, the value to store.
//
//  Until a measurement succeeds, `fallback` is used: the response fitted to the playtest
//  screenshots (a stored value t shows as about 255·(t/255)^0.48, which reproduces all
//  four chameleons measured in them to within 2%).
//
//  Plain Swift, so it's tested in Tools/coretest.
//

import Foundation

struct DisplayCurve: Sendable, Equatable {

    /// The stored value for each wanted one: `table[channel * 256 + wanted]`.
    private(set) var table: [UInt8]
    /// What each stored value shows as, the measurement this was built from (for
    /// diagnostics): `response[channel * 256 + stored]`.
    private(set) var response: [Float]
    /// How the camera picture itself is shown, against its pixel values (1 = as they say).
    private(set) var feed = SIMD3<Float>(repeating: 1)

    /// The stored values the calibration strip shows, left to right.
    static let patchLevels: [Int] = [12, 40, 72, 104, 136, 168, 200, 232]

    /// Stored and shown are the same (what a renderer that left colours alone would need).
    static let identity = DisplayCurve(responses: (0..<3).map { _ in (0..<256).map { Float($0) } })

    /// The response fitted to the playtest screenshots.
    static let fallback = DisplayCurve(exponent: 0.48)

    /// A renderer that shows a stored value t as 255·(t/255)^exponent, in every channel.
    init(exponent: Float) {
        let one = (0..<256).map { 255 * pow(Float($0) / 255, exponent) }
        self.init(responses: [one, one, one])
    }

    /// From a measurement: `shown[i]` is what stored value `levels[i]` looked like on
    /// screen (0…255 per channel). Nil if the readings can't be a grey ramp drawn on
    /// screen — the strip wasn't where it was looked for, or something was in the way —
    /// so that a bad reading never becomes every chameleon's colours.
    init?(levels: [Int], shown: [SIMD3<Float>]) {
        guard levels.count == shown.count, levels.count >= 4, levels == levels.sorted(),
              let first = levels.first, let last = levels.last, last > first else { return nil }
        var responses: [[Float]] = []
        for channel in 0..<3 {
            let values = shown.map { $0[channel] }
            // A ramp: it climbs, by a good amount, and never drops by more than noise.
            guard values[values.count - 1] - values[0] >= 80 else { return nil }
            for i in 1..<values.count where values[i] < values[i - 1] - 3 { return nil }
            // And it's drawn by something that shows greys roughly as greys: each level
            // within a generous range of itself.
            for (level, value) in zip(levels, values) {
                let low = Float(level) * 0.45 - 6, high = min(255, Float(level) * 2.6 + 60)
                guard value >= low, value <= high else { return nil }
            }
            // Through the readings, from black, and on past the last one at the slope it
            // ended with.
            var points: [(x: Float, y: Float)] = [(0, 0)]
            var top: Float = 0
            for (level, value) in zip(levels, values) {
                top = max(top, value)
                points.append((Float(level), top))
            }
            let a = points[points.count - 2], b = points[points.count - 1]
            let slope = max(0, (b.y - a.y) / max(b.x - a.x, 1))
            points.append((255, min(255, b.y + slope * (255 - b.x))))
            var curve = [Float](repeating: 0, count: 256)
            var segment = 0
            for stored in 0..<256 {
                while segment < points.count - 2, Float(stored) > points[segment + 1].x { segment += 1 }
                let p = points[segment], q = points[segment + 1]
                let t = (Float(stored) - p.x) / max(q.x - p.x, 1e-3)
                curve[stored] = p.y + (q.y - p.y) * min(max(t, 0), 1)
            }
            responses.append(curve)
        }
        // Grey in, grey out: the three channels can't be far apart.
        for stored in stride(from: 16, to: 256, by: 16) {
            let r = responses[0][stored], g = responses[1][stored], b = responses[2][stored]
            guard max(r, g, b) - min(r, g, b) <= 22 else { return nil }
        }
        self.init(responses: responses)
    }

    /// From what each stored value shows as, per channel (256 values each, climbing), and
    /// how the camera picture is shown against its own pixel values.
    private init(responses: [[Float]], feed: SIMD3<Float> = SIMD3<Float>(repeating: 1)) {
        var table = [UInt8](repeating: 0, count: 3 * 256)
        var flat = [Float](repeating: 0, count: 3 * 256)
        for channel in 0..<3 {
            let curve = responses[channel]
            var stored = 0
            for wanted in 0..<256 {
                // What the camera picture shows this colour as is what has to be matched.
                let target = min(max(Float(wanted) * feed[channel], 0), 255)
                // The first stored value that shows at least that bright, then whichever
                // of it and the one before is nearer. (Targets climb with `wanted`, so the
                // search carries on from where it was.)
                while stored < 255, curve[stored] < target { stored += 1 }
                var best = stored
                if stored > 0, abs(curve[stored - 1] - target) < abs(curve[stored] - target) { best = stored - 1 }
                table[channel * 256 + wanted] = UInt8(best)
            }
            for value in 0..<256 { flat[channel * 256 + value] = curve[value] }
        }
        self.table = table
        self.response = flat
        self.feed = feed
    }

    private var responses: [[Float]] {
        (0..<3).map { channel in (0..<256).map { response[channel * 256 + $0] } }
    }

    /// The stored value that shows as `wanted`.
    func stored(_ wanted: UInt8, channel: Int) -> UInt8 {
        table[channel * 256 + Int(wanted)]
    }

    /// What a stored value shows as, by the measurement.
    func shown(_ stored: UInt8, channel: Int) -> Float {
        response[channel * 256 + Int(stored)]
    }

    /// RGBA pixels as wanted on screen → RGBA pixels to store (alpha untouched).
    func apply(_ rgba: [UInt8]) -> [UInt8] {
        var out = rgba
        out.withUnsafeMutableBufferPointer { pixels in
            table.withUnsafeBufferPointer { lookup in
                var i = 0
                while i + 2 < pixels.count {
                    pixels[i] = lookup[Int(pixels[i])]
                    pixels[i + 1] = lookup[256 + Int(pixels[i + 1])]
                    pixels[i + 2] = lookup[512 + Int(pixels[i + 2])]
                    i += 4
                }
            }
        }
        return out
    }

    /// The same curve for a camera picture that's itself shown a little brighter or
    /// darker than its pixel values say (`gain` per channel, measured against the same
    /// screen): a wanted colour is first moved to what the picture shows it as.
    func matchingFeed(gain: SIMD3<Float>) -> DisplayCurve {
        DisplayCurve(responses: responses, feed: gain)
    }

    /// Halfway (or `weight` of the way) between two measurements, to steady the noise.
    func blended(with other: DisplayCurve, weight: Float = 0.5) -> DisplayCurve {
        var mixed: [[Float]] = []
        for channel in 0..<3 {
            mixed.append((0..<256).map { response[channel * 256 + $0] * (1 - weight) + other.response[channel * 256 + $0] * weight })
        }
        return DisplayCurve(responses: mixed, feed: feed * (1 - weight) + other.feed * weight)
    }

    /// Whether a reading agrees with what the playtest screenshots showed for bright
    /// greys (the only part of the curve they pin down): a way to tell a real measurement
    /// from a picture that wasn't of the screen as the player sees it.
    static func agreesWithScreenshots(levels: [Int], shown: [SIMD3<Float>], tolerance: Float = 0.15) -> Bool {
        var checked = 0
        for (level, value) in zip(levels, shown) where level >= 190 {
            let expected = fallback.shown(UInt8(min(level, 255)), channel: 1)
            guard abs(value.y - expected) <= expected * tolerance else { return false }
            checked += 1
        }
        return checked > 0
    }
}
