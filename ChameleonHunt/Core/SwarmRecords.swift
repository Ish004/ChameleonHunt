//
//  SwarmRecords.swift
//  Swarm's best times: the quickest anyone on this device has found every one, for each
//  level and each number hidden (v7.8).
//
//  Pass-and-play is played for bragging rights, and a game that remembers the record
//  gives every round a number to beat. The results say "New best" when it falls, and the
//  standing best otherwise, as one line under the score (the way Deezer, Duolingo and
//  most arcade games show a high score: the score big, the best small, a tag only when
//  it's beaten).
//
//  Only a clean sweep counts — every one found, without the hint — and only against the
//  same level and the same number hidden: six on Hard is a different game from two on
//  Easy. Kept on the device, like the coins.
//
//  Plain Swift, so it's tested in Tools/coretest.
//

import Foundation

enum SwarmRecords {

    /// One record per level and number hidden.
    static func key(difficulty: HuntDifficulty, hidden: Int) -> String {
        "\(difficulty.rawValue)-\(hidden)"
    }

    /// What a round leaves on the record: the best time for its key after this round, and
    /// whether this round set it.
    /// - Parameters:
    ///   - seconds: how long the seeker took (misses' seconds included: they came off
    ///     the clock).
    ///   - counts: whether this round can set a record at all (every one found, no hint).
    static func update(_ bests: inout [String: Int], key: String, seconds: Int, counts: Bool) -> (best: Int?, isNew: Bool) {
        let previous = bests[key]
        guard counts, seconds >= 0 else { return (previous, false) }
        guard previous.map({ seconds < $0 }) ?? true else { return (previous, false) }
        bests[key] = seconds
        return (seconds, true)
    }
}
