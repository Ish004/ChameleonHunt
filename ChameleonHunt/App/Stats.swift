//
//  Stats.swift
//  The player's record and best times, kept on this device (v7.9), for the profile page
//  and the results.
//
//  The rules are plain Swift in Core (PlayerStats, SwarmRecords); this keeps them in
//  UserDefaults, like the coins (Wallet), and publishes them for the screens.
//

import SwiftUI

@MainActor
final class Stats: ObservableObject {

    static let shared = Stats()

    @Published private(set) var record: PlayerStats
    /// Swarm's best times, by level and number hidden (SwarmRecords.key).
    @Published private(set) var swarmBests: [String: Int]

    private let defaults = UserDefaults.standard

    private init() {
        record = defaults.data(forKey: "playerStats").flatMap { try? JSONDecoder().decode(PlayerStats.self, from: $0) }
            ?? PlayerStats()
        swarmBests = defaults.dictionary(forKey: "swarmBests") as? [String: Int] ?? [:]
    }

    /// A hunt reached its end, as seeker or in a squad.
    func noteRound(found: Int, won: Bool) {
        record.noteRound(found: found, won: won)
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: "playerStats") }
    }

    /// Swarm: every one found. A record if it's the quickest clean sweep yet for this
    /// level and number hidden (and no hint). Returns the best as it now stands, and
    /// whether this round set it.
    func noteSwarmClear(difficulty: HuntDifficulty, hidden: Int, seconds: Int, hintUsed: Bool) -> (best: Int?, isNew: Bool) {
        var bests = swarmBests
        let result = SwarmRecords.update(&bests, key: SwarmRecords.key(difficulty: difficulty, hidden: hidden),
                                         seconds: seconds, counts: !hintUsed)
        if bests != swarmBests {
            swarmBests = bests
            defaults.set(bests, forKey: "swarmBests")
        }
        return result
    }

    /// The best for this level and number hidden, if there is one.
    func swarmBest(difficulty: HuntDifficulty, hidden: Int) -> Int? {
        swarmBests[SwarmRecords.key(difficulty: difficulty, hidden: hidden)]
    }
}
