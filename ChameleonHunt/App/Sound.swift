//
//  Sound.swift
//  Plays the game's sound effects (made in Core/SoundSynth.swift).
//
//  "Ambient" audio: it mixes with whatever music is playing and stays quiet when the
//  ring/silent switch is on silent, like most games. Off entirely with the Sound setting.
//
//  A handful of player nodes take turns, so quick sounds overlap instead of cutting
//  each other off. Nothing here hands a closure to AVFoundation: completion handlers run
//  on the audio thread, and a main-actor closure run there stops the app under Swift 6
//  (the squad crash in v6.5 was exactly that, with MultipeerConnectivity).
//

import AVFoundation
import SwiftUI

@MainActor
final class Sound {

    static let shared = Sound()

    /// The setting, stored so it's remembered (and readable with @AppStorage).
    nonisolated static let settingKey = "soundOn"
    var isOn: Bool { UserDefaults.standard.object(forKey: Self.settingKey) as? Bool ?? true }

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var buffers: [SoundEffect: AVAudioPCMBuffer] = [:]
    private var next = 0
    private var prepared = false
    private var preparing = false

    private init() {}

    /// Renders the effects in the background and sets up the engine. Call early; a sound
    /// asked for before it's ready is just skipped.
    func prepare() {
        guard !prepared, !preparing else { return }
        preparing = true
        Task {
            let rendered = await Task.detached(priority: .utility) {
                SoundEffect.allCases.map { ($0, SoundSynth.render($0)) }
            }.value
            setUp(rendered)
        }
    }

    private func setUp(_ rendered: [(SoundEffect, [Float])]) {
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: SoundSynth.sampleRate, channels: 1) else { return }
        for (effect, samples) in rendered {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { continue }
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            buffers[effect] = buffer
        }
        for _ in 0..<6 {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players.append(player)
        }
        prepared = true
    }

    func play(_ effect: SoundEffect) {
        guard isOn else { return }
        guard prepared, let buffer = buffers[effect], !players.isEmpty else { prepare(); return }
        // The engine stops when the audio route changes (headphones, a call); start it
        // again as needed rather than watching for it.
        if !engine.isRunning {
            try? AVAudioSession.sharedInstance().setActive(true)
            try? engine.start()
        }
        guard engine.isRunning else { return }
        let player = players[next]
        next = (next + 1) % players.count
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }
}
