//
//  HuntDifficulty.swift
//  How hard the hunt is, in Swarm and in Squad alike: the seeker picks it on SEEKER'S
//  TURN in Swarm, the host in the lobby in Squad.
//
//  Playtesters found Swarm a little too easy once they'd played a few rounds. Easy,
//  Medium and Hard each turn every lever a little further:
//   - camouflage: how closely each chameleon keeps matching the room around it;
//   - speed: how quickly it catches up when the seeker moves (what's behind it changes
//     with every step, and a slow chameleon shows as a patch of the old view);
//   - the tell: how far its colours are nudged off a perfect match. Since v7.3 its
//     colours reach the screen as the camera's own (DisplayCurve), which on a plain
//     surface would make it truly invisible; the tell keeps it "very slightly visible"
//     from a step away and plain right next to it, by an amount that's chosen rather
//     than an accident of rendering;
//   - distance: how soon it fades as the seeker backs away (DistanceFade);
//   - aim: how near a tap has to land to count;
//   - misses: from Medium on, a tap on nothing costs seconds, so tapping all over the
//     screen stops being a way to find them. In Swarm they come off the seeker's clock;
//     in Squad, where everyone shares one clock, that player can't tap for as long;
//   - time (Swarm only: in Squad the host sets the time outright): fewer extra seconds
//     for each chameleon after the first.
//  None of it is dramatic on its own; together Hard is a real search.
//
//  The two games hide chameleons with the same code and the same numbers (v7.1), so a
//  level means the same thing in both.
//

import Foundation

enum HuntDifficulty: String, CaseIterable, Codable, Sendable {
    case easy, medium, hard

    var title: String {
        switch self {
        case .easy: "Easy"
        case .medium: "Medium"
        case .hard: "Hard"
        }
    }

    /// One line under the choice, saying what it means.
    var detail: String {
        switch self {
        case .easy: "Easiest to spot. Misses are free."
        case .medium: "Better hidden. A miss costs \(missPenalty) s."
        case .hard: "Hardest to spot. A miss costs \(missPenalty) s."
        }
    }

    /// The level and what a miss costs, in a few words (the squad lobby's summary).
    var summary: String {
        missPenalty > 0 ? "\(title) · a miss costs \(missPenalty) s" : "\(title) · misses are free"
    }

    /// Added to the hunt's living camouflage strength (ScreenDifficulty's, about 0.69 on a
    /// phone to 0.82 on a 13" iPad).
    var camouflageBoost: Float {
        switch self {
        case .easy: -0.05
        case .medium: 0.05
        case .hard: 0.15
        }
    }

    /// How far each living-camouflage update moves towards what the camera sees now
    /// (LiveSkin.Settings.adaptRate), and how often the updates come, in seconds. On Hard
    /// a chameleon has caught up with a new view in about a quarter of a second; on Easy
    /// it takes about a second, and trails behind a seeker who keeps moving.
    var adaptRate: Float {
        switch self {
        case .easy: 0.45
        case .medium: 0.6
        case .hard: 0.8
        }
    }

    var refreshInterval: Double {
        switch self {
        case .easy: 0.2
        case .medium: 0.14
        case .hard: 0.1
        }
    }

    /// How far a chameleon's colours sit off a perfect match from a step away or more,
    /// and right next to it, as a fraction of full brightness (0.01 is about 2.5 of the
    /// 255 levels). Light surfaces go that much darker, dark ones that much lighter.
    /// For scale: the rendering fault fixed in v7.2 had them 0.05 off on a carpet (easy
    /// to spot, said the playtest) and 0.10–0.13 off on a white table (far too easy).
    var tell: (far: Float, close: Float) {
        switch self {
        case .easy: (0.045, 0.075)
        case .medium: (0.026, 0.058)
        case .hard: (0.013, 0.045)
        }
    }

    /// Metres: the full close-up tell within `tellCloseWithin`, down to the far one by
    /// `tellFarFrom`.
    static let tellCloseWithin: Float = 0.35
    static let tellFarFrom: Float = 1.0

    /// The tell from `distance` metres away.
    func tell(distance: Float) -> Float {
        let t = min(max((distance - Self.tellCloseWithin) / (Self.tellFarFrom - Self.tellCloseWithin), 0), 1)
        let eased = t * t * (3 - 2 * t)
        return tell.close + (tell.far - tell.close) * eased
    }

    /// The most the camouflage can be: a little of the paint always shows, and the lag
    /// as the seeker moves stays catchable.
    static let camouflageCeiling: Float = 0.95

    func camouflage(base: Float) -> Float {
        min(max(base + camouflageBoost, 0), Self.camouflageCeiling)
    }

    /// How the distance fade's range is scaled: where it's still fully clear, where it's
    /// faintest, and how faint that is.
    var fadeScale: (clear: Float, faint: Float, faintest: Float) {
        // Hard reaches a little further than it did (v7.2): playtesters lost sight of
        // them sooner than felt right.
        switch self {
        case .easy: (1, 1, 1)
        case .medium: (0.8, 0.95, 0.75)
        case .hard: (0.65, 0.95, 0.6)
        }
    }

    /// Points round a tap that still count as touching one.
    var tapReach: Float {
        switch self {
        case .easy: 26
        case .medium: 20
        case .hard: 14
        }
    }

    /// Seconds off the clock for a tap on nothing.
    var missPenalty: Int {
        switch self {
        case .easy: 0
        case .medium: 2
        case .hard: 5
        }
    }

    /// Extra seconds the seeker gets for each chameleon after the first.
    var secondsPerExtra: Int {
        switch self {
        case .easy: 12
        case .medium: 9
        case .hard: 6
        }
    }
}
