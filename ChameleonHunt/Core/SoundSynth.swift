//
//  SoundSynth.swift
//  The game's sound effects, made from scratch rather than recorded: a few sine-based
//  tones and bursts of noise with quick envelopes, the way chiptune and toy sounds are
//  built. Nothing to download or license, and each one is a few kilobytes of maths.
//
//  The palette is small and bright to match the look — a toy chameleon on a game show:
//  soft clicks for keys, a plop for dropping one, a two-note bell for FOUND, woodblock
//  ticks for the last ten seconds and the 3-2-1, a little fanfare for a win. Nothing
//  jokey (no sad trombone); losing gets a gentle falling phrase.
//
//  Plain Swift, so it renders off the main thread and is checked in Tools/coretest.
//  Playback is App/Sound.swift.
//

import Foundation

enum SoundEffect: String, CaseIterable, Sendable {
    /// Any key or chip being pressed. Very quiet.
    case tap
    /// A chameleon dropped into the room.
    case drop
    /// You found one.
    case found
    /// Someone else found one (squad).
    case foundOther
    /// The last ten seconds, and 3-2-1.
    case tick
    /// The hunt starts.
    case go
    /// The seeker (or you, in a squad) won.
    case win
    /// Time's up / someone else won.
    case lose
    /// A player joined the lobby.
    case join
    /// Tapped nothing.
    case miss
    /// The home screen's chameleon being poked.
    case poke
}

enum SoundSynth {

    static let sampleRate: Double = 44_100

    /// The samples for one effect, mono, peaking at its own loudness (never above 0.9).
    static func render(_ effect: SoundEffect) -> [Float] {
        var out: [Float]
        let loudness: Float
        switch effect {
        case .tap:
            out = tone(1600, duration: 0.03, decay: 0.006, partials: [(1, 1), (2.7, 0.3)])
            loudness = 0.16
        case .drop:
            out = tone(520, to: 170, duration: 0.14, decay: 0.05, partials: [(1, 1), (2, 0.18)])
            mix(&out, noise(duration: 0.03, decay: 0.008, smoothing: 0.75), at: 0, gain: 0.25)
            loudness = 0.55
        case .found:
            out = []
            mix(&out, bell(1318.5, duration: 0.55), at: 0)
            mix(&out, bell(1975.5, duration: 0.7), at: 0.09)
            loudness = 0.6
        case .foundOther:
            out = bell(987.8, duration: 0.5)
            loudness = 0.3
        case .tick:
            out = tone(1900, duration: 0.05, decay: 0.012, partials: [(1, 1), (2.9, 0.4)])
            loudness = 0.32
        case .go:
            out = []
            mix(&out, tone(1046.5, duration: 0.35, attack: 0.004, decay: 0.13, partials: chip), at: 0)
            mix(&out, tone(1568, duration: 0.35, attack: 0.004, decay: 0.13, partials: chip), at: 0, gain: 0.8)
            loudness = 0.5
        case .win:
            out = []
            // C E G, then a held C-E-G on top.
            for (i, f) in [523.3, 659.3, 784.0].enumerated() {
                mix(&out, tone(f, duration: 0.2, attack: 0.003, decay: 0.09, partials: chip), at: Double(i) * 0.085)
            }
            for f in [1046.5, 1318.5, 1568.0] {
                mix(&out, tone(f, duration: 0.8, attack: 0.004, decay: 0.32, partials: chip, vibrato: (5.5, 0.004)),
                    at: 0.26, gain: 0.7)
            }
            loudness = 0.55
        case .lose:
            out = []
            for (i, f) in [659.3, 523.3, 440.0].enumerated() {
                let last = i == 2
                mix(&out, tone(f, duration: last ? 0.6 : 0.22, attack: 0.01, decay: last ? 0.25 : 0.1,
                               partials: soft, vibrato: last ? (5, 0.006) : (0, 0)),
                    at: Double(i) * 0.17)
            }
            loudness = 0.4
        case .join:
            out = tone(300, to: 880, duration: 0.11, attack: 0.002, decay: 0.045, partials: [(1, 1), (2, 0.12)])
            loudness = 0.42
        case .miss:
            out = tone(150, to: 95, duration: 0.1, attack: 0.002, decay: 0.035, partials: [(1, 1)])
            mix(&out, noise(duration: 0.025, decay: 0.006, smoothing: 0.9), at: 0, gain: 0.3)
            loudness = 0.3
        case .poke:
            // A springy boing: up, back down a little, with a wobble that dies away.
            out = tone(320, to: 560, duration: 0.3, attack: 0.003, decay: 0.12, partials: [(1, 1), (2, 0.1)],
                       vibrato: (16, 0.06))
            loudness = 0.4
        }
        normalise(&out, to: min(loudness, 0.9))
        return out
    }

    // MARK: - Building blocks

    /// Soft chip-tune timbre: odd harmonics falling away fast, a triangle-ish sound.
    private static let chip: [(Double, Double)] = [(1, 1), (2, 0.08), (3, 0.14), (5, 0.04)]
    /// Rounder still, for the gentle falling phrase.
    private static let soft: [(Double, Double)] = [(1, 1), (2, 0.1), (3, 0.05)]

    /// A tone gliding from `from` to `to` (Hz), with a quick attack and an exponential
    /// decay (`decay` is the time to fall to 37%), made of the given partials
    /// (frequency ratio, level) and an optional vibrato (rate Hz, depth as a ratio).
    static func tone(_ from: Double, to: Double? = nil, duration: Double, attack: Double = 0.002, decay: Double,
                     partials: [(Double, Double)], vibrato: (Double, Double) = (0, 0)) -> [Float] {
        let count = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        var phase = [Double](repeating: 0, count: partials.count)
        let end = to ?? from
        for n in 0..<count {
            let t = Double(n) / sampleRate
            let progress = t / duration
            // Glides ease out, so they land rather than overshoot.
            let glide = 1 - (1 - progress) * (1 - progress)
            let wobble = 1 + vibrato.1 * sin(2 * .pi * vibrato.0 * t) * exp(-t / max(duration * 0.6, 0.01))
            let f = (from + (end - from) * glide) * wobble
            let envelope = min(t / max(attack, 1e-4), 1) * exp(-t / decay)
            // A 3 ms fade at the very end, so nothing clicks off.
            let tail = min((duration - t) / 0.003, 1)
            var value = 0.0
            for (k, partial) in partials.enumerated() {
                phase[k] += 2 * .pi * f * partial.0 / sampleRate
                value += sin(phase[k]) * partial.1
            }
            samples[n] = Float(value * envelope * tail)
        }
        return samples
    }

    /// A bell: bright attack, inharmonic partials that die away faster than the note.
    static func bell(_ frequency: Double, duration: Double) -> [Float] {
        tone(frequency, duration: duration, attack: 0.001, decay: duration * 0.35,
             partials: [(1, 1), (2.0, 0.3), (3.01, 0.14), (4.2, 0.07)])
    }

    /// A short burst of noise, smoothed (0 = raw, near 1 = dull thud). Deterministic, so
    /// every play and every test is the same.
    static func noise(duration: Double, decay: Double, smoothing: Double) -> [Float] {
        let count = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        var seed: UInt32 = 0x1234_5678
        var last = 0.0
        for n in 0..<count {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let white = Double(seed >> 8) / Double(1 << 24) * 2 - 1
            last = last * smoothing + white * (1 - smoothing)
            let t = Double(n) / sampleRate
            samples[n] = Float(last * exp(-t / decay))
        }
        return samples
    }

    /// Adds `other` into `into`, starting `at` seconds in.
    static func mix(_ into: inout [Float], _ other: [Float], at seconds: Double, gain: Float = 1) {
        let start = Int(seconds * sampleRate)
        if into.count < start + other.count { into += [Float](repeating: 0, count: start + other.count - into.count) }
        for i in other.indices { into[start + i] += other[i] * gain }
    }

    private static func normalise(_ samples: inout [Float], to peak: Float) {
        let loudest = samples.reduce(0) { max($0, abs($1)) }
        guard loudest > 0 else { return }
        let gain = peak / loudest
        for i in samples.indices { samples[i] *= gain }
    }
}
