//
//  PlayerStats.swift
//  The player's record on this device, for the profile page (v7.9): rounds played,
//  chameleons found, rounds won.
//
//  The party games this one takes after all keep a career record (Among Us's stats,
//  Fall Guys' crowns, Brawl Stars' trophies), and for a game played for bragging rights
//  it's the thing to show a friend. Three numbers, so the page stays short:
//   - Played: every hunt that reached its end (found, time's up, or given up), in any
//     game, as seeker or in a squad.
//   - Found: every chameleon this player found.
//   - Wins: a hunt where the seeker found them all (Swarm, Paint & Hide), or a squad round
//     where this player came top or level top with a point.
//
//  Plain Swift, so it's tested in Tools/coretest.
//

import Foundation

struct PlayerStats: Codable, Equatable, Sendable {
    var played = 0
    var found = 0
    var wins = 0

    /// A hunt reached its end.
    mutating func noteRound(found: Int, won: Bool) {
        played += 1
        self.found += max(0, found)
        if won { wins += 1 }
    }
}
