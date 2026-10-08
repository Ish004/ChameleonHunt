//
//  Coins.swift
//  What a find is worth.
//
//  Coins are the game's one currency: earned by finding chameleons (and, in a squad, by
//  hiding them well), spent on skins. They buy looks and nothing else: a chameleon in any
//  skin hides exactly as well as any other, the way the earned currencies of the party
//  games this takes after buy only cosmetics.
//
//  The rules, kept few enough to say on one screen:
//   - A find pays more the sooner it's made: the full amount at the start of the hunt,
//     sliding to half by the end. (Kahoot's scoring has the same shape. Slow still pays,
//     so nobody's punished for looking properly.)
//   - Harder levels pay more.
//   - The hint can be switched on at any moment; from then on that hunt's finds pay half.
//     One fixed cost, applied once, and said on the key before it's pressed.
//   - In a squad, each of your own that nobody found pays a little, and so does coming top.
//
//  Plain Swift, so it's tested in Tools/coretest.
//

import Foundation

enum CoinRules {

    /// What a find pays the instant the hunt starts, by difficulty.
    static func findBase(_ difficulty: HuntDifficulty) -> Int {
        switch difficulty {
        case .easy: 20
        case .medium: 30
        case .hard: 50
        }
    }

    /// Paint & Hide's one chameleon.
    static let paintAndHideBase = 40

    /// Squad: for each of your chameleons nobody found.
    static let unfoundBonus = 10
    /// Squad: for coming top of the board (everyone level at the top gets it).
    static let winBonus = 30

    /// How much of a find's coins the hint leaves.
    static let hintShare = 0.5

    /// A find made `elapsed` seconds into a hunt of `total`.
    static func find(base: Int, elapsed: Double, of total: Double, hintOn: Bool) -> Int {
        let gone = total > 0 ? min(max(elapsed / total, 0), 1) : 0
        let speed = 1 - gone / 2
        return max(1, Int((Double(base) * speed * (hintOn ? hintShare : 1)).rounded()))
    }

    /// What the end of a squad round pays `player`, beyond their finds: for each of theirs
    /// nobody found, and for being top (or level top) with at least a point.
    static func squadBonus(for player: UUID, in state: SquadState) -> (unfound: Int, win: Int) {
        let scores = SquadRules.scores(state)
        guard let mine = scores.first(where: { $0.player.id == player }) else { return (0, 0) }
        let top = scores.map(\.points).max() ?? 0
        return (mine.survivors * unfoundBonus, mine.points == top && top > 0 ? winBonus : 0)
    }
}
